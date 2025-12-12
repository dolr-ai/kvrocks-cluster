import os
import pathlib

import redis
from redis.cluster import RedisCluster
from dotenv import load_dotenv

load_dotenv()

BASE_DIR = pathlib.Path(__file__).resolve().parent
CERT_DIR = BASE_DIR / "certs"
CA_CERT = CERT_DIR / "ca.crt"
CLIENT_CERT = CERT_DIR / "client.crt"
CLIENT_KEY = CERT_DIR / "client.key"

MASTER_1 = "136.243.150.223"
MASTER_2 = "138.201.128.44"
REPLICA_1 = "136.243.173.190"
REPLICA_2 = "138.201.222.232"
TLS_PORT = 6666
PASSWORD = os.environ["KVROCKS_PASSWORD"]

for path in (CA_CERT, CLIENT_CERT, CLIENT_KEY):
    if not path.exists():
        raise FileNotFoundError(f"TLS file missing: {path}")

# Cluster-aware client - routes automatically over TLS via HAProxy
rc = RedisCluster(
    host=MASTER_1,
    port=TLS_PORT,
    password=PASSWORD,
    ssl=True,
    ssl_ca_certs=str(CA_CERT),
    ssl_certfile=str(CLIENT_CERT),
    ssl_keyfile=str(CLIENT_KEY),
)
rc.set("test", "out")
print("SET via cluster client: test=out")
print(f"GET via cluster client: test={rc.get('test').decode()}")

# Initialize from MASTER_2 and fetch the same key
rc2 = RedisCluster(
    host=MASTER_2,
    port=TLS_PORT,
    password=PASSWORD,
    ssl=True,
    ssl_ca_certs=str(CA_CERT),
    ssl_certfile=str(CLIENT_CERT),
    ssl_keyfile=str(CLIENT_KEY),
)
print(f"GET via cluster client (init from master-2): test={rc2.get('test').decode()}")

# Direct connection to replica-2 (plain Redis client) over TLS
replica = redis.Redis(
    host=REPLICA_2,
    port=TLS_PORT,
    password=PASSWORD,
    ssl=True,
    ssl_ca_certs=str(CA_CERT),
    ssl_certfile=str(CLIENT_CERT),
    ssl_keyfile=str(CLIENT_KEY),
)
try:
    result = replica.get("test")
    print(f"GET from replica-2 direct (TLS): {result}")
except redis.exceptions.ResponseError as e:
    print(f"MOVED redirect from replica-2: {e}")
