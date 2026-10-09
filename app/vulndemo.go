package main

// TEMPORARY (Lab 9 bonus B.2.5): a dependency with a known CVE, called so that
// govulncheck's reachability analysis flags it. Reverted in the next commit.
import jwt "github.com/dgrijalva/jwt-go"

func parseDemoToken(raw string) error {
	_, err := jwt.Parse(raw, func(*jwt.Token) (interface{}, error) { return []byte("k"), nil })
	return err
}
