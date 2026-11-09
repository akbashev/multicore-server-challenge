# feeds.py <out dir> <count> (not for upstream): posts bodies like the load generator's and saves the feed after each,
# as the server sends it without gzip.
import base64, hashlib, hmac, json, os, random, subprocess, sys, time, urllib.request

out, count = sys.argv[1], int(sys.argv[2])
secret = os.environ["JWT_SECRET"].encode()
rows = subprocess.run(["psql", "-qXAt", "-d", "feed_test", "-c", "SELECT id, username FROM users ORDER BY random() LIMIT 64"],
                      capture_output=True, text=True, check=True).stdout.split("\n")
users = [r.split("|") for r in rows if r]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def token(uid, name):
    now = int(time.time())
    h = b64(b'{"alg":"HS256","typ":"JWT"}')
    p = b64(json.dumps({"sub": uid, "username": name, "iat": now, "exp": now + 3600}, separators=(",", ":")).encode())
    return f"{h}.{p}.{b64(hmac.new(secret, f'{h}.{p}'.encode(), hashlib.sha256).digest())}"

def req(method, path, body=None, tok=None):
    headers = {"Content-Type": "application/json"} | ({"Authorization": f"Bearer {tok}"} if tok else {})
    with urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:3000" + path, data=body, method=method, headers=headers)) as r:
        return r.read()

os.makedirs(out, exist_ok=True)
for i in range(count):
    uid, name = random.choice(users)
    t = time.time()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % (int(t * 1000) % 1000)
    body = {"body": f"{name} says hi at {stamp} (VU {random.randint(1, 1_400_000)}, iter {random.randint(1, 40)})"}
    req("POST", "/posts", json.dumps(body).encode(), token(uid, name))
    open(f"{out}/{i:04d}.json", "wb").write(req("GET", "/feed"))
sizes = [os.path.getsize(f"{out}/{i:04d}.json") for i in range(count)]
print(f"{count} feeds, {min(sizes)}-{max(sizes)} bytes, mean {sum(sizes) / count:.0f}")
