# ==============================================================================
#  EasySB Makefile
#
#  常用入口 / the usual entry points:
#    make            构建二进制（等价于 make build）
#    make check      提交前的完整关卡：格式 + vet + 测试
#    make dist       交叉编译发布用的全部架构
#
#  版本号由 VERSION 经 go:embed 编进二进制，所以这里不传 -X main.version；构建标签
#  只有 release/TAGS 一处定义，构建、测试、发布读的都是同一个文件。
#  The version is embedded from VERSION, so nothing passes -X main.version, and the
#  build tag set lives only in release/TAGS: build, test and dist all read that file.
# ==============================================================================

GO      ?= go
BINARY  ?= easysb
DIST    ?= dist

# 标签与版本各读一处文件，绝不在 Makefile 里另抄一份。
# Tags and version each come from one file; they are never re-typed here.
TAGS    ?= $(shell tr -d '[:space:]' < release/TAGS)
VERSION := $(shell tr -d '[:space:]' < VERSION 2>/dev/null)
# COMMIT 可用命令行覆盖（CI 传入完整的 GITHUB_SHA）。
# COMMIT can be overridden on the command line (CI passes the full GITHUB_SHA).
COMMIT  ?= $(shell git rev-parse --short HEAD 2>/dev/null)

# 本地构建保留符号表，便于调试；发布构建去掉，与发布工作流一致。
# A local build keeps symbols for debugging; a release build strips them, matching CI.
LDFLAGS         := $(if $(strip $(COMMIT)),-X main.commit=$(COMMIT))
RELEASE_LDFLAGS := -s -w -checklinkname=0 $(LDFLAGS)

# 发布资产的架构名，与发布工作流一致（armv7 在 Go 里是 GOARCH=arm + GOARM=7）。
# Release asset architectures, matching CI (armv7 is GOARCH=arm with GOARM=7 in Go).
ARCHES := amd64 arm64 armv7 386 riscv64 s390x

# 资产名到 Go 目标三元组的映射，只定义一次，dist 与 dist-asset 共用。
# The asset-name to Go-target mapping, defined once and shared by dist and dist-asset.
GOARCH_amd64   := amd64
GOARCH_arm64   := arm64
GOARCH_armv7   := arm
GOARCH_386     := 386
GOARCH_riscv64 := riscv64
GOARCH_s390x   := s390x
GOARM_armv7    := 7

comma := ,
empty :=
space := $(empty) $(empty)

.DEFAULT_GOAL := build

.PHONY: build build-plain run test test-plain test-race vet fmt fmt-check \
        lint check render screens dist dist-asset release-matrix install tidy \
        version help clean

# --- 构建 / Build -------------------------------------------------------------

build: ## 构建二进制（带 release/TAGS 标签）
	$(GO) build -trimpath -tags "$(TAGS)" -ldflags "$(LDFLAGS)" -o $(BINARY) .

build-plain: ## 不带标签构建，便于快速迭代
	$(GO) build -trimpath -o $(BINARY) .

# --- 运行 / Run ---------------------------------------------------------------

run: build ## 构建后启动面板
	./$(BINARY)

render: build ## 渲染一帧桌面版式并退出
	./$(BINARY) --render --width 100 --height 40

screens: build ## 渲染所有页面并校验版式（需要 python3）
	python3 scripts/layout_check.py ./$(BINARY)

# --- 校验 / Checks ------------------------------------------------------------

test: ## 运行全部测试（带 release/TAGS 标签）
	$(GO) test -tags "$(TAGS)" ./...

test-plain: ## 不带标签运行测试（覆盖无流量统计的构建）
	$(GO) test ./...

test-race: ## 带竞态检测运行测试
	$(GO) test -tags "$(TAGS)" -race ./...

vet: ## go vet 静态检查
	$(GO) vet ./...

fmt: ## 就地格式化
	gofmt -w .

fmt-check: ## 校验格式，有差异即失败
	@unformatted="$$(gofmt -l .)"; \
	if [ -n "$$unformatted" ]; then \
		echo "需要 gofmt / gofmt needed:"; \
		echo "$$unformatted"; \
		exit 1; \
	fi
	@echo "gofmt: 干净 / clean"

lint: fmt-check vet ## 格式 + vet

check: lint test ## 提交前的完整关卡 / the pre-commit gate

# --- 发布 / Release -----------------------------------------------------------

dist: ## 交叉编译全部发布架构到 dist/
	@set -e; for asset in $(ARCHES); do \
		$(MAKE) --no-print-directory dist-asset ASSET=$$asset; \
	done
	@ls -lh $(DIST)

dist-asset: ## 交叉编译单个发布架构（ASSET=amd64 / arm64 / armv7 / 386 / riscv64 / s390x）
	@test -n "$(ASSET)" || { echo "ASSET 未设置 / ASSET required, one of: $(ARCHES)"; exit 1; }
	@test -n "$(GOARCH_$(ASSET))" || { echo "未知架构 / unknown asset: $(ASSET), one of: $(ARCHES)"; exit 1; }
	@mkdir -p $(DIST)
	GOOS=linux GOARCH=$(GOARCH_$(ASSET)) GOARM=$(GOARM_$(ASSET)) CGO_ENABLED=0 \
		$(GO) build -trimpath -tags "$(TAGS)" \
			-ldflags "$(RELEASE_LDFLAGS)" \
			-o "$(DIST)/easysb-linux-$(ASSET)" .
	@ls -lh "$(DIST)/easysb-linux-$(ASSET)"

release-matrix: ## 打印发布架构矩阵 JSON（发布工作流用来生成动态矩阵）
	@printf '%s\n' '$(ARCHES)' | sed 's/ /","/g; s/^/["/; s/$$/"]/'

install: build ## 用刚构建的二进制执行安装（需要 root）
	./install.sh --binary ./$(BINARY)

# --- 维护 / Maintenance -------------------------------------------------------

tidy: ## 整理 go.mod / go.sum
	$(GO) mod tidy

version: ## 打印版本、提交、标签与 Go 版本
	@echo "EasySB  $(VERSION)"
	@echo "commit  $(if $(strip $(COMMIT)),$(COMMIT),<none>)"
	@echo "tags    $(TAGS)"
	@echo "go      $$($(GO) version)"

clean: ## 删除构建产物（二进制与 dist/）
	rm -f $(BINARY)
	rm -rf $(DIST)

help: ## 显示本帮助
	@echo "EasySB make 目标 / targets:"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
