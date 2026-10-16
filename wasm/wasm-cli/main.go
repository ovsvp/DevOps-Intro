// Standalone WASI CLI build of the same Moscow-time logic (Lab 12 bonus).
// No Spin SDK: the request arrives as CGI-style environment variables and the
// response goes to stdout, which is all bare `wasmtime run` can offer.
package main

import (
	"fmt"
	"os"
	"time"
)

var moscow = time.FixedZone("MSK", 3*60*60)

func main() {
	method := os.Getenv("REQUEST_METHOD")
	path := os.Getenv("PATH_INFO")

	if method != "GET" || path != "/time" {
		fmt.Printf("Status: 404\n\n")
		return
	}

	now := time.Now().In(moscow)
	fmt.Printf("Content-Type: application/json\n\n")
	fmt.Printf(`{"unix":%d,"iso":%q,"hour_minute":%q,"zone":%q,"utc_offset_hours":3}`+"\n",
		now.Unix(), now.Format(time.RFC3339), now.Format("15:04"), "Europe/Moscow")
}
