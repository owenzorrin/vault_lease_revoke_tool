package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/fatih/color"
	"github.com/hashicorp/vault/api"
)

var (
	infoCol = color.New(color.FgGreen).SprintFunc()
	warnCol = color.New(color.FgYellow).SprintFunc()
	errCol  = color.New(color.FgRed).SprintFunc()
)

func main() {
	// 1. Define Command Line Flags
	reportCmd := flag.Bool("report", false, "Generate a lease count report")
	cleanCmd := flag.Bool("clean", false, "Run the irrevocable lease cleanup")
	limit := flag.Int("n", 0, "Number of leases to clean (0 = all)")
	parallel := flag.Int("p", 10, "Parallelism level (1-50)")
	autoApprove := flag.Bool("f", false, "Force/Auto-approve (skip y/n prompt)")
	flag.Parse()

	// 2. Initialize Vault Client
	config := api.DefaultConfig()
	client, err := api.NewClient(config)
	if err != nil {
		log.Fatalf("%s Failed to init Vault client: %v", errCol("[ERROR]"), err)
	}

	// Check for required env vars manually for better UX
	if os.Getenv("VAULT_TOKEN") == "" {
		log.Fatalf("%s VAULT_TOKEN environment variable is not set", errCol("[ERROR]"))
	}

	// 3. Route to requested functionality
	if *reportCmd {
		runReport(client)
	} else if *cleanCmd {
		runCleanup(client, *limit, *parallel, *autoApprove)
	} else {
		fmt.Println("Vault Lease Revoke Tool (v2 Go Implementation)")
		flag.Usage()
	}
}

// --- REPORTING LOGIC ---

func runReport(client *api.Client) {
	fmt.Printf("\n=== Vault Lease Report ===\nTime: %s\n\n", time.Now().Format(time.RFC1123))

	secret, err := client.Logical().List("sys/leases/lookup")
	if err != nil {
		log.Fatalf("%s Error listing mounts: %v", errCol("[ERROR]"), err)
	}

	if secret == nil || secret.Data["keys"] == nil {
		fmt.Println("No active lease mounts found.")
		return
	}

	keys := secret.Data["keys"].([]interface{})
	grandTotal := 0

	for _, k := range keys {
		mount := k.(string)
		mountClean := strings.TrimSuffix(mount, "/")
		fmt.Printf("Mount: %s\n", mountClean)

		mountTotal := 0
		rolesSecret, _ := client.Logical().List("sys/leases/lookup/" + mount + "creds")
		
		if rolesSecret != nil && rolesSecret.Data != nil && rolesSecret.Data["keys"] != nil {
			roles := rolesSecret.Data["keys"].([]interface{})
			for _, r := range roles {
				role := r.(string)
				leases, _ := client.Logical().List("sys/leases/lookup/" + mount + "creds/" + role)
				if leases != nil && leases.Data != nil {
					count := len(leases.Data["keys"].([]interface{}))
					fmt.Printf("  ├─ %s: %d leases\n", strings.TrimSuffix(role, "/"), count)
					mountTotal += count
				}
			}
			fmt.Printf("  └─ Total for %s: %d leases\n\n", mountClean, mountTotal)
		} else {
			fmt.Println("  └─ No creds found\n")
		}
		grandTotal += mountTotal
	}

	fmt.Printf("=== Grand Total ===\nTotal: %d leases\n", grandTotal)
}

// --- CLEANUP LOGIC ---

func runCleanup(client *api.Client, limit int, parallel int, autoApprove bool) {
	// 1. Fetch Irrevocable Leases
	secret, err := client.Logical().ReadWithData("sys/leases", map[string][]string{"type": {"irrevocable"}})
	if err != nil {
		log.Fatalf("%s Failed to fetch leases: %v", errCol("[ERROR]"), err)
	}

	if secret == nil || secret.Data["leases"] == nil {
		fmt.Println(infoCol("No irrevocable leases found."))
		return
	}

	allLeases := secret.Data["leases"].([]interface{})
	totalFound := len(allLeases)

	// 2. Apply Limit
	toRevoke := allLeases
	if limit > 0 && limit < totalFound {
		toRevoke = allLeases[:limit]
	}
	countToProcess := len(toRevoke)

	fmt.Printf("%s Found %d irrevocable leases.\n", infoCol("[INFO]"), totalFound)
	fmt.Printf("%s Preparing to process %d leases.\n", infoCol("[INFO]"), countToProcess)

	// 3. Confirmation
	if !autoApprove {
		fmt.Printf("\n%s Proceed with force-revocation of %d leases? (y/n): ", warnCol("[WARNING]"), countToProcess)
		reader := bufio.NewReader(os.Stdin)
		response, _ := reader.ReadString('\n')
		if !strings.HasPrefix(strings.ToLower(strings.TrimSpace(response)), "y") {
			fmt.Println("Operation cancelled.")
			return
		}
	}

	// 4. Parallel Workers
	var wg sync.WaitGroup
	semaphore := make(chan struct{}, parallel)
	
	start := time.Now()
	for i, l := range toRevoke {
		leaseData := l.(map[string]interface{})
		leaseID := leaseData["lease_id"].(string)

		wg.Add(1)
		go func(idx int, id string) {
			defer wg.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			// This is the direct API call for 'vault lease revoke -force -prefix <id>'
			// We use Logical().Write to access the raw sys path, which is most reliable across SDK versions.
			_, err := client.Logical().Write("sys/leases/revoke-force/"+id, nil)
			
			if err == nil {
				fmt.Printf("[%d/%d] %s Revoked: %s\n", idx+1, countToProcess, infoCol("✓"), id)
			} else {
				fmt.Printf("[%d/%d] %s Failed: %s | Error: %v\n", idx+1, countToProcess, errCol("✗"), id, err)
			}
		}(i, leaseID)
	}

	wg.Wait()
	fmt.Printf("\n%s Process completed in %v\n", infoCol("[SUCCESS]"), time.Since(start))
}
