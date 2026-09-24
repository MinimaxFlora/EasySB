package stats

import (
	"fmt"

	"google.golang.org/protobuf/encoding/protowire"
)

// methodQueryStats is the fully qualified gRPC method of the core's stats
// service. The service and message names are frozen by the v2ray API, which is
// why they are spelled out here rather than generated from a protobuf file.
const methodQueryStats = "/v2ray.core.app.stats.command.StatsService/QueryStats"

// The counter names the core publishes for one user. A suffix match is enough
// to tell the two directions apart.
const (
	userPrefix  = "user>>>"
	uplinkTag   = ">>>traffic>>>uplink"
	downlinkTag = ">>>traffic>>>downlink"
)

// rawMessage carries an already encoded protobuf payload through gRPC.
//
// EasySB needs exactly one call: QueryStats with no patterns, which returns
// every counter the core keeps. That request has one repeated string field and
// the response one repeated message field, so the panel encodes and decodes
// those by hand instead of shipping a generated client and its descriptor.
type rawMessage struct{ body []byte }

// rawCodec passes payloads through untouched.
type rawCodec struct{}

func (rawCodec) Marshal(v any) ([]byte, error) {
	m, ok := v.(*rawMessage)
	if !ok {
		return nil, fmt.Errorf("stats: cannot marshal %T", v)
	}
	return m.body, nil
}

func (rawCodec) Unmarshal(data []byte, v any) error {
	m, ok := v.(*rawMessage)
	if !ok {
		return fmt.Errorf("stats: cannot unmarshal into %T", v)
	}
	m.body = append(m.body[:0], data...)
	return nil
}

// Name keeps the gRPC content subtype at "proto" while the payload stays raw.
func (rawCodec) Name() string { return "proto" }

// queryStatsRequest encodes QueryStatsRequest{patterns, reset}: field 1 is the
// repeated pattern, field 2 the reset flag, which is never set because the panel
// diffs samples locally instead of letting the core clear its counters.
func queryStatsRequest(patterns ...string) *rawMessage {
	var body []byte
	for _, p := range patterns {
		body = protowire.AppendTag(body, 1, protowire.BytesType)
		body = protowire.AppendString(body, p)
	}
	return &rawMessage{body: body}
}

// stat is one counter of the stats service.
type stat struct {
	name  string
	value int64
}

// parseQueryStatsResponse decodes QueryStatsResponse{repeated Stat stat = 1}.
func parseQueryStatsResponse(body []byte) ([]stat, error) {
	var out []stat
	for len(body) > 0 {
		num, typ, n := protowire.ConsumeTag(body)
		if n < 0 {
			return nil, protowire.ParseError(n)
		}
		body = body[n:]
		if num == 1 && typ == protowire.BytesType {
			payload, m := protowire.ConsumeBytes(body)
			if m < 0 {
				return nil, protowire.ParseError(m)
			}
			one, err := parseStat(payload)
			if err != nil {
				return nil, err
			}
			out = append(out, one)
			body = body[m:]
			continue
		}
		m := protowire.ConsumeFieldValue(num, typ, body)
		if m < 0 {
			return nil, protowire.ParseError(m)
		}
		body = body[m:]
	}
	return out, nil
}

// parseStat decodes Stat{name = 1, value = 2}.
func parseStat(body []byte) (stat, error) {
	var s stat
	for len(body) > 0 {
		num, typ, n := protowire.ConsumeTag(body)
		if n < 0 {
			return s, protowire.ParseError(n)
		}
		body = body[n:]
		switch {
		case num == 1 && typ == protowire.BytesType:
			name, m := protowire.ConsumeString(body)
			if m < 0 {
				return s, protowire.ParseError(m)
			}
			s.name = name
			body = body[m:]
		case num == 2 && typ == protowire.VarintType:
			value, m := protowire.ConsumeVarint(body)
			if m < 0 {
				return s, protowire.ParseError(m)
			}
			s.value = int64(value)
			body = body[m:]
		default:
			m := protowire.ConsumeFieldValue(num, typ, body)
			if m < 0 {
				return s, protowire.ParseError(m)
			}
			body = body[m:]
		}
	}
	return s, nil
}
