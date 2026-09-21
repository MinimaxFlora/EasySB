package subscribe

import (
	"encoding/json"
	"testing"
)

func TestOrderedJSONRoundTrip(t *testing.T) {
	in := []byte(`{"b":1,"a":{"z":true,"y":[1,"two",null]},"c":"x"}`)
	v, err := parseOrderedJSON(in)
	if err != nil {
		t.Fatal(err)
	}
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(out); got != string(in) {
		t.Fatalf("key order not preserved:\n got %s\nwant %s", got, in)
	}
}

func TestOrderedJSONSetKeepsPosition(t *testing.T) {
	v, err := parseOrderedJSON([]byte(`{"first":1,"second":2,"third":3}`))
	if err != nil {
		t.Fatal(err)
	}
	v.setNumber("second", 20)
	v.setString("fourth", "4")
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"first":1,"second":20,"third":3,"fourth":"4"}`
	if got := string(out); got != want {
		t.Fatalf("set rewrote order:\n got %s\nwant %s", got, want)
	}
}
