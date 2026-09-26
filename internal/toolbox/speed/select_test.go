package speed

import (
	"reflect"
	"testing"
)

// ids is what a selection test asserts on: which servers were picked, in order.
func ids(servers []server) []string {
	if len(servers) == 0 {
		return nil
	}
	out := make([]string, 0, len(servers))
	for _, srv := range servers {
		out = append(out, srv.id)
	}
	return out
}

func TestPickNearest(t *testing.T) {
	list := []server{
		{id: "a", name: "A", distance: 120},
		{id: "b", name: "B", distance: 5},
		{id: "c", name: "C", distance: 60},
		{id: "d", name: "D", distance: 900},
	}
	tests := []struct {
		name string
		list []server
		n    int
		want []string
	}{
		{name: "nearest first", list: list, n: 2, want: []string{"b", "c"}},
		{name: "n covers the list", list: list, n: 4, want: []string{"b", "c", "a", "d"}},
		{name: "n beyond the list", list: list, n: 9, want: []string{"b", "c", "a", "d"}},
		{name: "n zero", list: list, n: 0, want: nil},
		{name: "n negative", list: list, n: -1, want: nil},
		{name: "empty list", list: nil, n: 4, want: nil},
		{
			name: "an unknown distance keeps the list order, behind a known one",
			list: []server{{id: "x"}, {id: "y", distance: 3}, {id: "z"}},
			n:    2,
			want: []string{"y", "x"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			before := ids(tt.list)
			if got := ids(pickNearest(tt.list, tt.n)); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("pickNearest() = %v, want %v", got, tt.want)
			}
			// The caller's list is the fetched list; a selection must not reorder it.
			if after := ids(tt.list); !reflect.DeepEqual(after, before) {
				t.Errorf("pickNearest reordered its input: %v -> %v", before, after)
			}
		})
	}
}

func TestPickCarriers(t *testing.T) {
	tests := []struct {
		name string
		list []server
		want []string
	}{
		{
			name: "one per carrier, nearest first within a carrier",
			list: []server{
				{id: "t-far", name: "广州", sponsor: "中国电信", distance: 200},
				{id: "u", name: "北京", sponsor: "中国联通", distance: 900},
				{id: "m", name: "上海", sponsor: "中国移动", distance: 120},
				{id: "t-near", name: "深圳", sponsor: "中国电信", distance: 15},
			},
			want: []string{"t-near", "u", "m"},
		},
		{
			name: "the carrier keyword may sit in the sponsor alone",
			list: []server{
				{id: "u", name: "Guangzhou", sponsor: "中国联通 Guangdong", distance: 30},
			},
			want: []string{"u"},
		},
		{
			name: "no carrier at all",
			list: []server{
				{id: "jp", name: "Tokyo", sponsor: "Softbank", distance: 5},
				{id: "sg", name: "Singapore", sponsor: "Singtel", distance: 4000},
			},
			want: nil,
		},
		{
			name: "an English sponsor that only looks like a carrier is not one",
			list: []server{
				{id: "us", name: "Mobile, AL", sponsor: "T-Mobile USA", distance: 1},
			},
			want: nil,
		},
		{name: "empty list", list: nil, want: nil},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ids(pickCarriers(tt.list)); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("pickCarriers() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestCarrierOf(t *testing.T) {
	tests := []struct {
		name string
		srv  server
		want string
	}{
		{name: "name", srv: server{name: "电信节点"}, want: "电信"},
		{name: "sponsor", srv: server{sponsor: "中国联通上海"}, want: "联通"},
		{name: "mobile", srv: server{name: "上海", sponsor: "中国移动"}, want: "移动"},
		{name: "none", srv: server{name: "Tokyo", sponsor: "Softbank"}, want: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := carrierOf(tt.srv); got != tt.want {
				t.Errorf("carrierOf(%+v) = %q, want %q", tt.srv, got, tt.want)
			}
		})
	}
}

func TestCarrierCounts(t *testing.T) {
	targets := []server{
		{id: "t1", sponsor: "中国电信"},
		{id: "t2", sponsor: "中国电信"},
		{id: "m1", sponsor: "中国移动"},
	}
	want := []string{"电信 2", "移动 1"}
	if got := carrierCounts(targets); !reflect.DeepEqual(got, want) {
		t.Errorf("carrierCounts() = %v, want %v", got, want)
	}
	if got := carrierCounts(nil); len(got) != 0 {
		t.Errorf("carrierCounts(nil) = %v, want nothing", got)
	}
}

func TestSelectionDistances(t *testing.T) {
	tests := []struct {
		name   string
		list   []server
		want   string
		wantOK bool
	}{
		{
			name:   "span of the known distances",
			list:   []server{{distance: 9.03}, {distance: 148.23}, {distance: 60}},
			want:   "9.03 km ～ 148.23 km",
			wantOK: true,
		},
		{
			name:   "a single known distance is its own span",
			list:   []server{{distance: 40}, {}},
			want:   "40.00 km ～ 40.00 km",
			wantOK: true,
		},
		{
			name:   "no distance reported",
			list:   []server{{}, {}},
			wantOK: false,
		},
		{name: "empty", list: nil, wantOK: false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := selectionDistances(tt.list)
			if ok != tt.wantOK || got != tt.want {
				t.Errorf("selectionDistances() = (%q, %v), want (%q, %v)", got, ok, tt.want, tt.wantOK)
			}
		})
	}
}
