import os
import redis
from redis.cluster import RedisCluster
from dotenv import load_dotenv

load_dotenv()

MASTER_1 = "136.243.150.223"
MASTER_2 = "138.201.128.44"
REPLICA_1 = "136.243.173.190"
REPLICA_2 = "138.201.222.232"
PORT = 6666
PASSWORD = os.environ["KVROCKS_PASSWORD"]

# Cluster-aware client - routes automatically
rc = RedisCluster(host=MASTER_1, port=PORT, password=PASSWORD)
rc.set("test", "out")
print(f"SET via cluster client: test=out")
print(f"GET via cluster client: test={rc.get('test').decode()}")

# Initialize from MASTER_2 and fetch the same key
rc2 = RedisCluster(host=MASTER_2, port=PORT, password=PASSWORD)
print(f"GET via cluster client (init from master-2): test={rc2.get('test').decode()}")

# Direct connection to replica-2 (dumb client) - will show MOVED
replica = redis.Redis(host=REPLICA_2, port=PORT, password=PASSWORD)
try:
    result = replica.get("test")
    print(f"GET from replica-2 direct: {result}")
except redis.exceptions.ResponseError as e:
    print(f"MOVED redirect from replica-2: {e}")
