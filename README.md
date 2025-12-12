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

# 2. Deploy everything
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
  port: 6666
  workers: 8
  topology_version: 1  # Increment when changing topology

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

## Connecting from Application

Use a cluster-aware Redis client:

```python
from redis.cluster import RedisCluster

rc = RedisCluster(
    host="136.243.150.223",  # Any node works as entry point
    port=6666,
    password="your_password"
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
# Connect in cluster mode (-c flag handles MOVED redirects)
redis-cli -h 136.243.150.223 -p 6666 -a YOUR_PASSWORD -c

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
ssh kvrocks-master-1 "docker volume rm root_kvrocks_data"
ssh kvrocks-master-2 "docker volume rm root_kvrocks_data"
ssh kvrocks-replica-1 "docker volume rm root_kvrocks_data"
ssh kvrocks-replica-2 "docker volume rm root_kvrocks_data"

# Reset topology version to 1 in config.yml, then:
./deploy.sh
```

### Create Backup
On each server:
```bash
REDISCLI_AUTH=YOUR_PASSWORD redis-cli -h localhost -p 6666 BGSAVE
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
