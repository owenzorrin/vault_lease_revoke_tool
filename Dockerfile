# --- Stage 1: Build ---
FROM golang:1.21-alpine AS builder

# Set the working directory
WORKDIR /app

# Copy dependency files first (for better caching)
COPY go.mod go.sum ./
RUN go mod download

# Copy the source code
COPY . .

# Build the binary (statically linked for Alpine)
RUN CGO_ENABLED=0 GOOS=linux go build -o vlrt main.go

# --- Stage 2: Final Image ---
FROM alpine:3.18

# Add CA certificates for Vault TLS connections
RUN apk --no-cache add ca-certificates

# Create a non-root user for security
RUN adduser -D vaultuser
USER vaultuser

# Copy binary from the builder stage
COPY --from=builder /app/vlrt /usr/local/bin/vlrt

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/vlrt"]
