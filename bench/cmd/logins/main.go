// Command logins (not for upstream) drives POST /api/users/login with the seed's users at a fixed concurrency and
// reports logins per second and the server's CPU per login, read from its cgroup over the measured window. A login
// is one bcrypt cost-10 verify plus a user lookup, so this is mostly the server's bcrypt.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"conduitbench/seed"
)

// cpuStat returns usage, user and system microseconds from a cgroup v2 cpu.stat.
func cpuStat(cgroup string) (usage, user, system int64) {
	b, err := os.ReadFile(cgroup + "/cpu.stat")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		v, _ := strconv.ParseInt(f[1], 10, 64)
		switch f[0] {
		case "usage_usec":
			usage = v
		case "user_usec":
			user = v
		case "system_usec":
			system = v
		}
	}
	return
}

func main() {
	target := flag.String("target", "http://127.0.0.1:3000", "server base URL")
	conc := flag.Int("c", 64, "concurrent clients, each on its own keep-alive connection")
	warm := flag.Duration("warmup", 5*time.Second, "unmeasured warm-up")
	dur := flag.Duration("d", 20*time.Second, "measured window")
	cgroup := flag.String("cgroup", "", "the server's cgroup directory, for its CPU over the window")
	flag.Parse()

	tr := &http.Transport{MaxIdleConnsPerHost: *conc, MaxConnsPerHost: *conc, DisableCompression: true}
	client := &http.Client{Transport: tr, Timeout: 30 * time.Second}
	var ok, bad atomic.Int64
	var measuring, stop atomic.Bool
	var wg sync.WaitGroup
	for i := 0; i < *conc; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for !stop.Load() {
				id := rand.Int64N(100000) + 1
				body, _ := json.Marshal(map[string]any{"user": map[string]string{"email": seed.Email(id), "password": seed.Password}})
				resp, err := client.Post(*target+"/api/users/login", "application/json", bytes.NewReader(body))
				good := err == nil && resp.StatusCode == 200
				if resp != nil {
					io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
				}
				if measuring.Load() {
					if good {
						ok.Add(1)
					} else {
						bad.Add(1)
					}
				}
			}
		}()
	}
	time.Sleep(*warm)
	u0, us0, s0 := cpuStat(*cgroup)
	t0 := time.Now()
	measuring.Store(true)
	time.Sleep(*dur)
	measuring.Store(false)
	secs := time.Since(t0).Seconds()
	u1, us1, s1 := cpuStat(*cgroup)
	stop.Store(true)
	wg.Wait()

	n := ok.Load()
	fmt.Printf("LOGINS ok=%d failed=%d in %.1fs: %.0f/s", n, bad.Load(), secs, float64(n)/secs)
	if *cgroup != "" && n > 0 {
		fmt.Printf("; server %.2f cores (%.2f user, %.2f kernel) = %.2f ms CPU per login",
			float64(u1-u0)/1e6/secs, float64(us1-us0)/1e6/secs, float64(s1-s0)/1e6/secs, float64(u1-u0)/1e3/float64(n))
	}
	fmt.Println()
}
