package main

import (
	"fmt"
	"net/http"
	"time"

	spinhttp "github.com/spinframework/spin-go-sdk/v2/http"
)

// Moscow is UTC+3 year-round -- Russia abolished seasonal clock changes in
// 2011. A fixed zone is used instead of time.LoadLocation("Europe/Moscow")
// because TinyGo ships no tzdata, so the lookup would fail at runtime.
var moscow = time.FixedZone("MSK", 3*60*60)

func init() {
	spinhttp.Handle(func(w http.ResponseWriter, r *http.Request) {
		now := time.Now().In(moscow)

		w.Header().Set("Content-Type", "application/json")
		// Rendered with Sprintf rather than encoding/json: the payload is a
		// handful of fixed fields, and TinyGo's reflection support makes
		// marshalling map[string]any unreliable.
		fmt.Fprintf(w,
			`{"unix":%d,"iso":%q,"hour_minute":%q,"zone":%q,"utc_offset_hours":3}`+"\n",
			now.Unix(),
			now.Format(time.RFC3339),
			now.Format("15:04"),
			"Europe/Moscow",
		)
	})
}

// main function must be included for the compiler but is not executed.
func main() {}
