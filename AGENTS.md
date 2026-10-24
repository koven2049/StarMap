# StarMap Agent Rules

> Scope: the StarMap repository root

## Read First

If this repository is nested inside a larger workspace, read any parent `AGENTS.md` files first. In every workspace, including a standalone open-source clone, continue with the local files in this order:

1. `README.md` or `README.zh.md`
2. `01_Web/README.md`
3. `01_Web/AGENTS.md`
4. `TravelAtlas_Handoff.md` only when it exists in a private development workspace

Missing MediaLab parent files are expected in a standalone clone and are not a blocker. Local StarMap rules remain authoritative for product and media-import work.

## Fast Task Routing

### Map imagery credentials, access, or deployment

When a user asks about Cesium ion, Tianditu, tokens, keys, missing imagery, open-source setup, source switching, or deployment:

1. Explain the three supported sources first: bundled Natural Earth II always works at low resolution; Cesium ion enables online global imagery; Tianditu provides an alternative online source with Chinese labels. Cesium remains the 3D globe engine in every state.
2. Distinguish roles. Ordinary visitors use the deployed site's configuration. Every person who clones and deploys StarMap supplies their own provider credentials; never reuse or distribute the original author's values.
3. Never ask the user to paste a complete token or key into chat, and never read, echo, screenshot, log, copy, or store it. Guide direct entry into the external private layer's `config/.env.local` for personal development or the hosting platform's environment settings for production.
4. Document `VITE_MAP_SOURCE`, `VITE_CESIUM_ION_TOKEN`, and `VITE_TIANDITU_TOKEN` from `01_Web/.env.example`. `VITE_MAP_SOURCE` accepts `auto`, `cesium`, `tianditu`, or `local`; `auto` chooses the first configured online source and then the local fallback.
5. Treat both online values as public-client credentials: keeping them out of Git prevents repository disclosure, but a built static website necessarily exposes them to browser requests. Production safety comes from app-specific credentials plus each provider's URL, asset, scope, quota, monitoring, and rotation controls.
6. Recommend separate development and production credentials. Do not invent production restrictions while the final domain or provider requirements are unknown.
7. The source menu's green light means only that the required environment variable is non-empty; it does not prove that a credential is valid or authorized. Verify live imagery behavior separately without inspecting or reporting the value.

### Personal photo or drone-media import

When a user mentions uploading, importing, organizing, or adding travel photos or drone media:

1. Read `02_Assets/MediaInbox/README.md` first, then read `03_Reference/TravelAtlas_media_import_protocol.md` before inspecting or changing media. Real media lives in the external private layer's `MediaInbox/`; the tracked Inbox is documentation and a neutral template only.
2. If the user only asks how to upload, explain the folder workflow first; do not modify files or run the import.
3. If the user asks to perform the import, verify that every item has a reliable existing country and city, and that drone metadata is sufficient for the requested result.
4. If a country, city, media type, date, coordinate, privacy status, or intended use is missing or uncertain, ask the smallest necessary question and stop. Without a reliable answer, do not guess, copy, convert, catalog, or import that item. A zero-exit preflight does not override this stop rule when its warnings reveal unresolved data.
5. Source media inside `MediaInbox` is immutable. The only Agent-writable Inbox files are the private control sidecars `country.json` and city-level `media.json`; conversions and other derivatives must never be written there.

## Project Boundary

- This folder is the unique active home of StarMap.
- The runnable application lives in `01_Web/`; run all npm commands from that directory.
- Git is rooted at this project folder so code, project documentation, tests, and process records share one history.
- Do not create a second active StarMap copy.

## Map Architecture

- Cesium is the primary Map implementation.
- Daily map, route, marker, camera, and drone-media work targets `01_Web/src/components/CesiumAtlasGlobe.tsx` and related Cesium components.
- `01_Web/src/components/AtlasGlobe.tsx` is legacy/frozen react-globe code. Keep it for rollback reference and change it only when explicitly requested.
- Preserve the existing Map / Journey / About structure and shared theme state unless the user asks for a structural change.

## Working Method

1. Read the current README and, when present, the private workspace Handoff; choose one bounded task.
2. Inspect only relevant files; do not recursively scan `node_modules`, `dist`, `.git`, or large media folders.
3. Make surgical changes and verify them with `npm run lint` and `npm run build:public` from `01_Web/`.
4. Keep visual checks focused. Do not leave unbounded browser, terminal, or watcher sessions running.
5. In a private workspace that contains `TravelAtlas_Handoff.md`, update it after substantive work. Do not create one in a clean public clone unless the user asks.

## Local Preview

Use the standard Vite entry from `01_Web/`:

```powershell
npm run dev:personal
```

- Do not use a Node API wrapper to start Vite.
- StarMap has one codebase with two explicit profiles: `dev:personal` loads the external private layer and enables the loopback editor; `dev:public` loads only the neutral tracked sample and exposes no editor. They are runtime profiles, not two code editions.
- Deterministic edits must write directly through the loopback-only local editor with validation, backup, and atomic replacement. Do not reintroduce chat-command or AI-command relays for sorting, hiding, covers, uploads, or form saves.
- Public builds must render no editor controls and expose no write API. Never rely on CSS-hiding a control as the security boundary.
- Media added from the local editor must enter the external private layer's `MediaInbox/` first and then use the existing check/import pipeline. Never write personal uploads into tracked source paths.
- Do not use `--host 0.0.0.0` unless explicitly requested.
- Check whether a port is already occupied before starting another server.
- Do not stop or interfere with servers belonging to other projects.

## Assets and Secrets

- Public project-owned media belongs under tracked `02_Assets/` or `01_Web/public/`. Personal source media, derivatives, data, and configuration belong only in the external `06_private/` layer.
- Do not commit personal travel media to a future public template without an explicit publication review.
- Never read, print, copy, or commit `.env.local`, tokens, cookies, credentials, or secrets. `.gitignore` is defense in depth; the primary boundary is that `06_private/` is physically outside this Git repository.
- Never ask a user to paste a complete token into chat or task output; direct entry by the user is the only acceptable configuration path.
- Document required variables only in `01_Web/.env.example`.

## Git

- Work on the current feature branch unless the user requests another branch.
- Do not push without explicit approval.
- Keep generated output, local review screenshots, dependencies, and environment files out of Git.

## Documentation

- Public guide: [`README.md`](README.md)
- Chinese guide: [`README.zh.md`](README.zh.md)
- Web workspace: [`01_Web/README.md`](01_Web/README.md)
- Media workflow: [`02_Assets/MediaInbox/README.md`](02_Assets/MediaInbox/README.md)
- Privacy boundary: [`03_Reference/TravelAtlas_open_source_privacy_boundary.md`](03_Reference/TravelAtlas_open_source_privacy_boundary.md)

## 本地多终端开发约定（fork 侧追加；与上文冲突时以本节为准）

> 本节为多终端 / 多 agent 并行开发的补充纪律（2026-10-24 从个人 harness 合并）。
> 上文上游规则的"Do not push without explicit approval"由本节「合并即推」取代。

### 开工先拉最新

任何要动文件的任务开工前按序执行：`git fetch --prune` → `git status --short`
（主目录若有他人未提交改动：不动、不顺手提交，先问清归属）→ `git pull origin main`。
本仓库 main 每周一由 GitHub Actions（`.github/workflows/sync-upstream.yml`）自动
合并上游，**先拉再改是硬要求**。开工顺带巡检：`git branch --merged origin/main`
清已合并残留分支，`git worktree list` 清已合并分支挂着的空壳 worktree（`-d` /
remove 天然不会误删未合并内容）；未合并或含未提交改动的一律不动，报告用户。

### 动代码必走 worktree

- 任务触碰任何代码 / 测试文件 → **整任务**进 worktree（顺带的文档更新一起做）；
  只改文档、配置、纯资源或一处 typo 可直接在 main 上做（照常 commit + 推送）。
  不以「当前只有我一个终端」为由豁免——无法知道别的会话 / 机器是否在途。
- 位置与命名：worktree 建在**仓库同级** `.worktree/` 目录下，子目录
  `StarMap-wt-<简述>`（目录名必须以仓库标识开头）；分支 `feat/<简述>` /
  `fix/<简述>` / `task/<简述>`，简述 kebab-case ≤20 字符。
- worktree 复用主目录依赖，不重复 `npm ci`：
  `ln -s <主目录>/01_Web/node_modules 01_Web/node_modules`。
- **dev 服务器与 `06_private/` 私有层归主目录所有**：worktree 内不要跑
  `dev:personal`（会落到 worktree 自己的空私有层）；验证用 `npm run lint` +
  `npm run build:public`，确需起服务时以
  `STARMAP_PRIVATE_ROOT=<主目录>/06_private` 在独立端口临时运行。
- 切分支前工作区必须干净（commit 或 stash），绝不带着未提交改动 checkout。
- 收尾：worktree 内 commit → 主目录 `git merge` 回 main → `git push origin main`
  （合并即推）→ `git worktree remove` → `git branch -d`；`-d` 失败说明未真合并，
  停下排查，禁止 `-D` 硬删。硬判定：`branch --merged origin/main` 除 main 无输出、
  `worktree list` 只剩主目录、主分支与远程推平，全部满足才算完成。

### 提交与推送纪律

- Conventional Commits，subject ≤50 字符；diff 超过 10 行必须写正文说明 why。
- push 前危险文件扫描：`git diff origin/main..HEAD --name-only` 中不得出现
  `06_private/`、`.env*`、`*token*`、`credentials*`、私人媒体或 `06_private`
  的任何内容；`.gitignore` 只是第二道保险。
- 临时文件（`/tmp` 清单、调试截图、长输出）任务收尾即删。
