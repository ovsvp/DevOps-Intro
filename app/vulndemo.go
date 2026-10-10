package main

// TEMPORARY (Lab 9 bonus B.2.5): golang.org/x/text v0.3.0 carries GO-2021-0113
// and language.Parse is the vulnerable symbol. Called from init() so the call
// graph actually reaches it -- declaring it without calling it is invisible to
// govulncheck. Reverted in the next commit.
import "golang.org/x/text/language"

var demoTag string

func init() {
	if t, err := language.Parse("en-US"); err == nil {
		demoTag = t.String()
	}
}
