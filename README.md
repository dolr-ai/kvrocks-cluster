# Kvrocks Cluster

Self-hosted Kvrocks cluster deployment for the recommendation system. 4-node cluster with 2 masters and 2 replicas for high availability.

## Cluster Topology

| SSH Alias | IP | Role | Slots |
|-----------|-----|------|-------|
| kvrocks-master-1 | 136.243.150.223 | Master 1 | 0-8191 |
| kvrocks-master-2 | 138.201.128.44 | Master 2 | 8192-16383 |
| kvrocks-replica-1 | 136.243.173.190 | Replica 1 | (replicates Master 1) |
| kvrocks-replica-2 | 138.201.222.232 | Replica 2 | (replicates Master 2) |

## Directory Structure

```
kvrocks-cluster/
  config.yml                      # Cluster topology configuration
  docker-compose.yml              # Container template (deployed to all nodes)
  deploy.sh                       # Unified deployment script
  .env                            # Password (not in git)
  .env.example                    # Template for .env
  haproxy/haproxy.cfg             # HAProxy mTLS frontend config (TLS on 6666 -> 6667)
  certs/                          # Place CA, server.pem, and client certs (not committed)
  python_test_requirements.txt    # Python dependencies for test script
  test_node_agnostic_set_fetch.py # Test script for cluster connectivity
  README.md
```

## Prerequisites

1. **SSH config** with aliases in `~/.ssh/config`:
   ```
   Host kvrocks-master-1
     HostName 136.243.150.223
     User root
     IdentityFile ~/.ssh/id_ed25519

   Host kvrocks-master-2
     HostName 138.201.128.44
     User root
     IdentityFile ~/.ssh/id_ed25519

   Host kvrocks-replica-1
     HostName 136.243.173.190
     User root
     IdentityFile ~/.ssh/id_ed25519

   Host kvrocks-replica-2
     HostName 138.201.222.232
     User root
     IdentityFile ~/.ssh/id_ed25519
   ```

2. **Docker** installed on all 4 servers
3. **redis-cli** installed locally (for cluster setup commands)
4. **yq** installed locally (auto-installed by deploy.sh if missing)

## Quick Start

```bash
# 1. Set up password
cp .env.example .env
# Edit .env and set KVROCKS_PASSWORD

# 2. Place certs (not in git)
# certs/ca.crt, certs/server.pem, certs/client.crt, certs/client.key

# 3. Deploy everything
./deploy.sh
```

This will:
1. Install `yq` if needed (for YAML parsing)
2. Copy docker-compose.yml to all servers via SSH
3. Create temporary .env files on servers (deleted after use for security)
4. Start Kvrocks containers (v2.14.0) on all nodes
5. Setup cluster topology (node IDs, slot distribution)
6. Verify cluster health

## Usage

```bash
./deploy.sh              # Full deployment (deploy + setup + verify)
./deploy.sh deploy       # Only deploy containers to all nodes
./deploy.sh setup        # Only setup cluster topology
./deploy.sh verify       # Only verify cluster health
./deploy.sh stop         # Stop all containers
```

## Configuration

### Password (.env)

```bash
# .env (not committed to git)
KVROCKS_PASSWORD=your_secure_password_here
```

### Cluster Settings (config.yml)

```yaml
cluster:
  port: 6667              # Plaintext Kvrocks (HAProxy listens on 6666 TLS)
  workers: 8
  topology_version: 4  # Increment when changing topology

nodes:
  - name: master1
    ssh_alias: kvrocks-master-1
    ip: 136.243.150.223
    role: master
    slots: "0-8191"

  - name: replica1
    ssh_alias: kvrocks-replica-1
    ip: 136.243.173.190
    role: slave
    master: master1
  # ... more nodes
```

## HAProxy mTLS frontend

- HAProxy terminates TLS with client cert verification on port 6666 and forwards plaintext to Kvrocks on 6667.
- Required files under `certs/` (not committed): `ca.crt`, `server.pem` (server cert + key), `client.crt`, `client.key`.
- Generate CA:
  ```bash
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 365 -subj "/CN=kvrocks-internal-ca" -out ca.crt
  ```
- Generate node server cert with IP SAN (edit IPs/DNS as needed):
  ```bash
  cat > san.ext <<'EOF'
  subjectAltName = IP:136.243.150.223,IP:138.201.128.44,IP:136.243.173.190,IP:138.201.222.232
  EOF
  openssl req -new -newkey rsa:4096 -nodes -keyout server.key -out server.csr -subj "/CN=kvrocks-node"
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 365 -sha256 -extfile san.ext
  cat server.crt server.key > server.pem
  ```
- Generate client cert (repeat per app/user):
  ```bash
  openssl req -new -newkey rsa:4096 -nodes -keyout client.key -out client.csr -subj "/CN=redis-client"
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 365 -sha256
  ```
- Place `ca.crt`, `server.pem`, `client.crt`, `client.key` in `certs/` on each node before `docker compose up`.

## Connecting from Application

Use a cluster-aware Redis client:

```python
import os
from redis.cluster import RedisCluster

rc = RedisCluster(
    host="136.243.150.223",  # Any node works as entry point
    port=6666,               # TLS via HAProxy
    password=os.environ["KVROCKS_PASSWORD"],
    ssl=True,
    ssl_ca_certs="certs/ca.crt",
    ssl_certfile="certs/client.crt",
    ssl_keyfile="certs/client.key",
)

# For async:
from redis.asyncio.cluster import RedisCluster
```

## Testing

```bash
# Install test dependencies
uv pip install -r python_test_requirements.txt

# Run test script
python test_node_agnostic_set_fetch.py
```

## Testing with redis-cli

```bash
# Connect in cluster mode with mTLS (-c flag handles MOVED redirects)
redis-cli -h 136.243.150.223 -p 6666 -c --tls \
  --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  -a YOUR_PASSWORD

# Test commands
SET foo bar
GET foo
CLUSTER INFO
CLUSTER NODES
```

## Operations

### Check Cluster Status
```bash
./deploy.sh verify
```

### Stop All Nodes
```bash
./deploy.sh stop
```

### Restart Cluster
```bash
./deploy.sh stop
./deploy.sh deploy
# Note: Cluster topology persists, no need to run setup again
```

### Full Reset (Clean Slate)
```bash
./deploy.sh stop

# Delete data volumes on each server

# Reset topology version to 1 in config.yml, then:
./deploy.sh
```

### Create Backup
On each server:
```bash
REDISCLI_AUTH=YOUR_PASSWORD redis-cli --tls \
  --cacert certs/ca.crt --cert certs/client.crt --key certs/client.key \
  -h localhost -p 6666 BGSAVE
```

## Important Notes

1. **Namespaces disabled**: Kvrocks cluster mode does NOT support namespaces
2. **No automatic failover**: Manual intervention required if a master fails
3. **Topology updates**: Must apply to ALL nodes with incremented version number
4. **Data persists**: Docker volumes preserve data across restarts
5. **Kvrocks version**: Pinned to 2.14.0 in docker-compose.yml

## References

- [Kvrocks Cluster Documentation](https://kvrocks.apache.org/docs/cluster/)
- [Kvrocks GitHub](https://github.com/apache/kvrocks)
- [Kvrocks Releases](https://github.com/apache/kvrocks/releases)
