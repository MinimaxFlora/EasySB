package i18n

import (
	"fmt"
	"math/rand"
)

type Lang string

const (
	Chinese Lang = "C"
	English Lang = "E"
)

func Parse(s string) Lang {
	switch s {
	case "E", "e", "en", "EN", "english":
		return English
	default:
		return Chinese
	}
}

func (l Lang) Name() string {
	if l == English {
		return "English"
	}
	return "简体中文"
}

func (l Lang) Code() string {
	if l == English {
		return "EN"
	}
	return "中文"
}

func (l Lang) Toggle() Lang {
	if l == English {
		return Chinese
	}
	return English
}

var (
	zhTable = map[string]string{}
	enTable = map[string]string{}
)

func init() {
	for _, e := range table {
		zhTable[e.key] = e.cn
		enTable[e.key] = e.en
	}
}

func (l Lang) T(key string) string {
	m := zhTable
	if l == English {
		m = enTable
	}
	if v, ok := m[key]; ok {
		return v
	}
	return key
}

func (l Lang) Format(key string, args ...any) string {
	return fmt.Sprintf(l.T(key), args...)
}

func (l Lang) Hitokoto() string {
	quotes := hitokotoCN
	if l == English {
		quotes = hitokotoEN
	}
	if len(quotes) == 0 {
		return ""
	}
	return quotes[rand.Intn(len(quotes))]
}
