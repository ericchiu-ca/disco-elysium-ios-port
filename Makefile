# Disco Elysium iPadOS 移植工具链。完整流程：./setup.sh，然后 make install push-data run
# Disco Elysium iPadOS port toolchain. Full flow: ./setup.sh, then make install push-data run
# 每一步的说明见 README.zh-CN.md；配置在 config.env（参考 config.example.env）。make help 列出全部目标。
# Each step is described in README.md; configuration lives in config.env (see config.example.env). make help lists every target.

SHELL := /bin/bash
S := scripts

.PHONY: help check all fetch binaries stubs project build build-nosign data install push-data run logs smoke clean distclean \
        achievements achievements-unlock achievements-sync relay-pair relay relay-install relay-uninstall relay-status

help:           ## 列出全部目标 | List every target
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | expand -t 22

check:          ## 体检：逐项报告缺什么、下一步命令，不改任何东西 | Health check: report what is missing and the next command; changes nothing
	@./setup.sh check

all: fetch binaries stubs project build data  ## 准备全部（./setup.sh 会先体检再调用它） | Prepare everything (./setup.sh runs the health check first, then this)

fetch:          ## 下载并解包同版本的 Unity iOS 运行时（官方 CDN，约 530 MB） | Download and unpack the matching Unity iOS runtime (official CDN, about 530 MB)
	@$(S)/fetch_unity_ios.sh

binaries:       ## 把 GameAssembly / AmplifyTextureNative 的 arm64 部分改标为 iOS | Retag the arm64 slices of GameAssembly / AmplifyTextureNative as iOS
	@$(S)/prepare_binaries.sh

stubs:          ## 生成 Steam / GOG / InControl / OpenGL 桩库 | Build the Steam / GOG / InControl / OpenGL stub libraries
	@$(S)/build_stubs.sh

project: fetch  ## 生成 Xcode 工程（build/xcode），含 Trampoline 与 BC 纹理补丁 | Generate the Xcode project (build/xcode), including the Trampoline and BC texture patches
	@$(S)/gen_project.sh

build:          ## 编译并签名 App | Build and sign the app
	@$(S)/build.sh

build-nosign:   ## 只编译不签名（验证工具链用） | Build without signing (to check the toolchain)
	@$(S)/build.sh --no-sign

data: fetch     ## 转换游戏数据到 build/GameData（增量） | Convert the game data into build/GameData (incremental)
	@$(S)/convert_data.sh

install:        ## 安装 App 到 iPad | Install the app on the iPad
	@$(S)/device.sh install

push-data:      ## 推送游戏数据到 iPad 上的 App 沙盒（只传有变化的文件） | Push the game data into the app's sandbox on the iPad (changed files only)
	@$(S)/device.sh push-data

run:            ## 启动并在终端显示游戏日志 | Launch and stream the game log to the terminal
	@$(S)/device.sh run

logs:           ## 取回 iPad 上的 Player.log 与截图 | Fetch Player.log and snapshots from the iPad
	@$(S)/device.sh logs

smoke:          ## 设备冒烟测试：启动、收集日志与截图、逐项检查 | On-device smoke test: launch, collect log and snapshots, check each item
	@$(S)/smoke_test.sh

achievements:   ## 列出 Steam 成就和解锁状态（Steam 要已登录） | List the Steam achievements and whether they are unlocked (Steam must be logged in)
	@$(S)/achievements.sh list

achievements-unlock: ## 手动解锁：make achievements-unlock NAMES="ACH_KIM ACH_CUNO" | Unlock by hand: make achievements-unlock NAMES="ACH_KIM ACH_CUNO"
	@$(S)/achievements.sh unlock $(NAMES)

achievements-sync: ## 经 USB 同步 iPad 记下的成就到 Steam，再写回最新状态 | Sync the achievements recorded on the iPad to Steam over USB, then write the state back
	@$(S)/achievements.sh sync

relay-pair:     ## 生成 iPad 与 Mac 共用的配对密钥（写进 config.env） | Generate the pairing secret shared by the iPad and the Mac (written to config.env)
	@$(S)/achievements.sh pair

relay:          ## 在前台运行成就实时转发服务（DRY_RUN=1 只记日志） | Run the live achievement relay in the foreground (DRY_RUN=1 only logs)
	@$(S)/achievements.sh serve $(if $(DRY_RUN),--dry-run)

relay-install:  ## 把实时转发装成登录后自动运行的后台服务 | Install the live relay as a background service that starts at login
	@$(S)/achievements.sh install

relay-uninstall: ## 卸载后台转发服务 | Remove the background relay service
	@$(S)/achievements.sh uninstall

relay-status:   ## 后台转发服务的状态和最近日志 | Status and recent log of the background relay service
	@$(S)/achievements.sh status

clean:          ## 删除构建产物（保留下载的 Unity 包与转换好的数据） | Delete build output (keeps the downloaded Unity package and the converted data)
	rm -rf build/xcode build/DerivedData build/Frameworks build/tmp build/*.log

distclean:      ## 删除全部生成内容，包括转换好的游戏数据和 vendor/ | Delete everything generated, including the converted game data and vendor/
	rm -rf build vendor
