# The toolbox

The 工具箱 section is where a host is measured: one entry per measurement, one report per
entry, and a board that remembers what the last run of each entry found.

It replaces the 服务解锁状态 page, which was only the first of these measurements.

## What it holds

Everything in the table below is started by hand from the section's menu (or by
`sb --tool <id>`). Nothing runs when the section is opened: a speed test, a traceroute or a
disk benchmark is not something a navigation key should start.

| Entry | id | What it measures |
| :--- | :--- | :--- |
| 流媒体解锁 | `unlock-media` | Netflix, Disney+, YouTube Premium, Prime Video, DAZN, TVBAnywhere+, Spotify, Reddit, TikTok |
| AI 解锁 | `unlock-ai` | ChatGPT, Gemini, Claude |
| 区域解锁 | `unlock-region` | Steam, the three Bilibili catalogues, 巴哈姆特動畫瘋 |
| 三网回程 | `backtrace` | ICMP path to telecom / unicom / mobile targets, and which carrier carries the return traffic |
| 就近测速 | `speed-near` | Down, up and latency against nearby speedtest.net servers |
| 三网测速 | `speed-cn` | The same against Chinese telecom / unicom / mobile servers only |
| IP 质量 | `ipquality` | Country, ASN, IP type and proxy flags from several keyless databases, plus DNS blocklists |
| 邮件端口 | `portcheck` | Ports 25/465/587/110/995/143/993 against the public address, PTR and FCrDNS |
| 系统信息 | `hw-info` | CPU, cache, virtualisation, memory, load, time zone, ASN |
| 硬盘信息 | `hw-disk` | Block devices, capacity, model, rotational flag, power-on hours where SMART is readable |
| CPU 跑分 | `bench-cpu` | Single and multi-core score from the panel's own workload |
| 内存测试 | `bench-mem` | Sequential read, write and copy bandwidth |
| 磁盘 IO | `bench-disk` | Sequential write and read with fsync, then random 4K read and write IOPS |
| 多盘 IO | `bench-disks` | The same run on every mounted block device |

## How a result is shown

A tool returns a table (headers, rows) plus notes. The panel draws the table, wraps the
notes under it and puts one summary line on the board. Words the panel defined — the
verdicts `unlocked`, `blocked`, `unknown` — are worded by the panel, in whichever language
the interface is running; everything else is left exactly as the tool wrote it, because a
tool is the only thing that knows what its numbers mean.

The verdict words are deliberately short:

| Token | 中文 | English | Meaning |
| :--- | :--- | :--- | :--- |
| `unlocked` | 解锁 | unlocked | the service answered, and its own answer says this address is served |
| `blocked` | 不解锁 | blocked | the service refused this address, or offered it only partly (a half-working service is not a working one) |
| `unknown` | 未知 | unknown | the answer could not be read — a Cloudflare challenge, a timeout, a page with no verdict in it |

`unknown` is the one that matters: a probe that cannot read an answer says so instead of
guessing, and the note under the table says what it saw.

## Where the numbers come from

Nothing in the toolbox downloads a program. Every tool is Go code in this binary:

| Tool | Its numbers come from |
| :--- | :--- |
| the unlock entries | one to three HTTP requests per service, parsed by `internal/unlock` |
| `backtrace` | ICMP probes from this host (needs root, which the panel has), then ip-api.com for the ASN of the hops |
| `speed-near`, `speed-cn` | speedtest.net, through `github.com/showwin/speedtest-go` — the same library 融合怪 uses, in-process |
| `ipquality` | nine keyless databases (ip-api.com, ipinfo.io, ipapi.is, ipwho.is, ip.sb, ip2location.io, ipwhois.app, db-ip.com, ipapi.co) plus twelve DNS blocklists |
| `portcheck` | TCP connects to this host's own public address, and PTR/FCrDNS lookups |
| `hw-info`, `hw-disk` | `/proc` and `/sys`, with `statfs` on the mount points (the numbers `df` prints); `systemd-detect-virt`, `timedatectl` and `smartctl` only if they are installed, otherwise those cells say what could not be read |
| the benchmarks | the panel's own workloads, measured with the standard library clock |

Two consequences are worth stating plainly, because the numbers look like other tools'
numbers:

- **The CPU score is not a geekbench score and the disk numbers are not fio's.** They are
  this panel's own workloads. They compare a host against the same panel on another host,
  and they will not match a geekbench 5/6 result. The tests do not reach for sysbench, fio,
  dd or geekbench, because a panel whose premise is that it installs nothing is not going to
  download a benchmark.
- **测速 is speedtest.net, not a carrier's speed test.** 三网测速 filters the server list for
  Chinese carriers; from an overseas host that list is often empty, and the tool says so
  rather than measuring somewhere else and calling it 三网.

## Where it comes from

The section is this project's own Go implementation of the measurements
[融合怪 ecs](https://github.com/spiritLHLS/ecs) made popular (itself a融合 of bench.sh,
superbench, yabs, lemonbench and others), with two rules that differ on purpose:

- **No external binaries, no third-party scripts.** ecs downloads and runs other people's
  shell scripts; this panel runs Go code it carries. So the entries that are inherently an
  external program are absent by design: geekbench 4/5/6, sysbench, fio, mtr/nexttrace and
  the "third-party scripts area". Where a measurement could be re-implemented, it was —
  the CPU, memory and disk benchmarks are the panel's own.
- **Nothing is shared by itself.** ecs uploads its report to a paste service and prints a
  link; the panel keeps results in memory for its board. A run leaves the host only as
  requests to the services being measured.

Two ecs features are also absent because they need something this panel does not have:
the 24-hour ping (a background sampler) and the sharing link (an upload). Neither is
promised anywhere in the interface.

## Which words the panel owns

Three things are worded by the panel, in whichever language the interface runs: every entry's
name and description, the verdicts (`unlocked` / `blocked` / `unknown`), and the unlock
entries' table headers — the three unlock entries return tokens rather than sentences, which
is why that table reads the same in 中文 and English.

Every other tool words its own table, and those words are the tool's own: the row labels of
the benchmarks and of 系统信息 / 硬盘信息 are English (`Sequential write`, `Single core`,
`Mount`, `Sequential read`), while 三网回程, 测速, IP 质量 and 邮件端口 word theirs in Chinese,
with the technical columns left in English (`ASN`, `ISP`, `PTR`). They are left as the tool
wrote them on purpose: a tool is the only thing that knows what its numbers mean, and a
translation layer between a measurement and its label is a place for a number to end up under
the wrong word.

## Adding a tool

1. Write the tool in its own package under `internal/toolbox/<name>`, taking
   `toolbox.Options` and returning `toolbox.Result`. Everything that reaches outside the
   process (HTTP, DNS, dials, external commands, the clock) comes from `Options`, so the
   tests never touch the network or need root.
2. Register it in `internal/toolbox/tools` with an id and a group. The menu, the board and
   `sb --tool` all read that list, so one entry is the whole integration.
3. Add `toolbox_<id>` and `desc_toolbox_<id>` to `internal/i18n/table.go`, in both
   languages.
4. If the tool reports a verdict, report it as one of the three tokens above rather than as
   a word, so the interface can word it.

## The unlock probes in detail

The three unlock entries are a Go re-implementation of
[RegionRestrictionCheck](https://github.com/lmc999/RegionRestrictionCheck): one to three HTTP
requests per service, then a read of the body. No login, no captcha solving, no data files.

Two verdicts invite a second look, and both are deliberate:

- **Prime Video** serves its storefront in several shapes: a ~520 KB page whose geo block sits
  about 170 KB in, a multi-megabyte one whose block sits further, and a lean ~40 KB one that
  carries no geo information at all, plus the odd 503. Which one arrives varies between
  requests for the same address — the reference script's own `curl` command hits the empty
  shape too (measured: once in three runs there, three times in six here). The probe reads to
  the marker (cap 8 MB) and asks again, up to three attempts, before it reports a country as
  unreadable; the failure text says how many KB it read and how many attempts it made.
- **Claude** answers a datacenter address with a Cloudflare challenge (HTTP 403). The
  reference script reads an unchanged URL as "yes", which would call a challenge available;
  the panel reports `unknown` and attaches the region read from `claude.ai/cdn-cgi/trace`,
  because a challenge says Cloudflare distrusts the address — it says nothing about the
  country.

### Where the unlock probes differ from the reference script

Sixteen of the seventeen services ask the same endpoint and read the same field as the
reference script. The differences are deliberate and all of them are listed here:

| Item | Difference | Why |
| :--- | :--- | :--- |
| Prime Video | reads to the geo marker (cap 8 MB) and makes up to three attempts before failing | the script makes one `curl`, and reports `Failed (Error: PAGE ERROR)` whenever the storefront answers with its lean shape |
| YouTube Premium | also requires `ad-free` before it says yes, reading to that marker | the same final gate as the script, so a region alone cannot pass as an offer |
| Claude | a challenge page is `unknown`, with the region attached | the script reads an unchanged URL as "yes", which would call a Cloudflare challenge available |
| ChatGPT | reads the value of `unsupported_country` | the script's `grep` also matches `"unsupported_country":false`, turning a working country into a "no" |
| Disney+ | asks the GraphQL session for `location{countryCode}`; an unread region is a failure, not a "no" | the script's query returns no location, and an empty region is reported as "No" |
| Steam | parses `meta itemprop="priceCurrency"` and falls back to the `steamCountry` cookie | the script's `cut -d '"' -f4` depends on field order |
| TikTok | the script has no TikTok check | ours adds one browser-header retry to tell "region only under browser headers" from a block |
| IPv6 | no IPv6 branch | the script reports these services as unsupported over IPv6; the panel judges from the host's default egress |
| The rest | the script also measures OneTrust, iQyi, Bing/Apple regions, Wikipedia editability, Google Play, CDN ownership and more | the panel keeps the seventeen that matter to running a node |
