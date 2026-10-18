## 改了什么 / What changed

<!-- 几句话说明这次改动做了什么。 / What this change does, in a few sentences. -->

## 为什么 / Why

<!-- 解决的问题；有相关 issue 就链接上。 / The problem it solves. Link the issue if there is one. -->

## 跑过的检查 / Checks run

<!-- 勾选你在这次改动上真正跑过的，有输出的贴最后一行；没跑的不要勾。 -->
<!-- Tick what you actually ran on this change and paste the last line of output where there is one. Leave unticked what you did not run. -->

不需要游戏文件 / No game files needed:

- [ ] `bash -n` 全部脚本 / on every script, `python3 -I -m py_compile tools/*.py`

需要游戏文件 / Game files needed:

- [ ] `./setup.sh check`
- [ ] `make project build-nosign`
- [ ] `make data`

需要 iPad / An iPad needed:

- [ ] `make install push-data`
- [ ] `make smoke`（贴最后一行 / paste the last line）
- [ ] 手动验证（列出你点了什么）/ Manual check (list what you tried):

- [ ] 文档同时更新了中英文版本 / Both the English and Chinese docs were updated
- [ ] 新的注释是中英双语 / New comments are bilingual
