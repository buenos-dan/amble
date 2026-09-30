# Amble

一个在 **运行中的 Emacs** 内的纯 Elisp 助手，支持自然对话和编辑器操作。它可以理解编辑器状态、发现已安装包的能力、查询文档、调用函数、组合 Elisp 操作、编辑未保存的文本并验证结果。Git 和 Org 是附带的便捷工具；计划、日程与待办统一调用 zk，amble 不维护独立的 TODO 文件。

## 使用

需要支持 HTTPS/TLS 的 Emacs 31.1 和能访问 ModelHub 的网络。

使用内置 `use-package` 的 `:vc` 从 GitHub 安装，由 `package.el` 管理加载路径：

```elisp
(use-package amble
  :ensure nil
  :vc (:url "https://github.com/buenos-dan/amble.git"
       :branch "main"
       :rev :newest)
  :demand t
  :bind ("C-c e" . amble-toggle-popup)
  :config
  (amble-mode 1))
```

`:ensure nil` 避免再去 ELPA/MELPA 查找，`:vc` 仍会自动安装。首次安装取 main 的最新提交，之后可用 `M-x package-vc-upgrade RET amble` 更新，不会每次启动都拉取。

启动 Emacs 前在其环境中设置 `EMACS_AMBLE_API_KEY`。Amble 从该变量读取密钥；

可选配置：

```elisp
(setopt amble-reasoning-effort 'medium
        amble-reasoning-summary 'auto
        amble-extra-instructions "请用中文简短回复，优先沿用我的现有 Emacs 配置。")
```

在当前工作 buffer 里运行 `M-x amble` 或使用你配置的切换按键，打开浮动面板，在同一个 `*amble*` 缓冲区末尾的 `You` 下直接编写消息。`RET` 换行，`C-c C-c` 发送，无需 minibuffer。模型会根据当前 buffer、窗口、项目和会话历史决定怎么做。执行结果直接显示在原生 Emacs 窗口，过程记录在 `*amble*`。

```text
这里的 TAB 实际执行什么？为什么？
查一下有哪些和书签有关的命令，教我用最合适的那个
新建一个阅读计划 buffer，写三个目标，放在当前文档右边
把刚才那个计划改成 Org 格式，并把光标放在第二项
显示这个项目的 git diff
清理闲置 buffer
显示这个 Org 文档里的图片
在任务列表添加「读五本书」
```

这不是关键词到函数的映射：每一步都是实际模型请求，agent 可自行查询新能力、组合操作，并根据工具错误调整做法。

| 命令 | 行为 |
|---|---|
| `amble` | 打开会话并定位到末尾草稿；从 Lisp 调用 `(amble "消息")` 可直接提交 |
| `amble-show` | 显示会话并定位到末尾草稿 |
| `amble-input-send` | 发送末尾 `You` 下的草稿 |
| `amble-context` | 本地预览将自动发送的上下文，不调用模型 |
| `amble-cancel` / `C-g` | 取消网络请求及尚未执行的工具；已完成操作保留 |
| `amble-new-session` | 清除模型会话历史，保留编辑器状态 |
| `amble-reopen-cleaned` | 重新打开本次会话清理掉的文件 buffer |

Amble 会话显示在工作 frame 上方的浮动 child frame 中，打开、隐藏不会新增分屏或改变工作窗口尺寸。上面的 `:bind` 示例使用 `C-c e` 显示/隐藏，包本身不设置此全局绑定，可按个人习惯修改；按 `Esc` 隐藏并回到工作 frame，任务继续运行。`C-g` 才会取消任务。面板需要图形界面 Emacs，终端模式会明确提示。

`*amble*` 使用独立的按键范围，保留文字编辑、选择、复制粘贴、撤销、搜索、滚动、输入法和 Amble 操作。全局快捷键中绑定到这些命令的自定义按键也会保留，包括你配置的 Amble 切换键。不相关的全局和 minor mode 按键（例如切换 buffer、分屏、打开文件、`M-x`、退出 Emacs）会被拦截。快捷键被拦截、输入为空或任务仍在进行等提示只在 minibuffer 回显区短暂显示，不写入 `*Messages*`；header-line 仅显示模型、状态和发送按键。按 `Esc` 返回工作 frame 后使用原有快捷键。

工具操作与上下文读取固定在发起任务的工作 frame 中；即使输入焦点位于聊天面板，左右分屏和结果仍展示在工作 frame。工作 frame 被关闭时停止操作，不自动转到其他窗口。面板可从边框拖动，父 frame 大小变化后自动重新适配。可通过 `amble-frame-width`、`amble-frame-height` 调整宽高占比（默认 0.48、0.45）。

输入、回复和工具步骤都在同一个 `*amble*` 缓冲区中，不再拆分输入窗格。末尾 `You` 下是当前草稿，`RET` 换行，`C-c C-c` 发送；`C-c C-i` 可从历史记录跳回草稿。`q` 和 `i` 都是普通输入字符，`Esc` 隐藏面板。历史回复只读，折叠标题上的 `TAB` / `RET` 仍可展开详情。

异步回复和工具日志插入到草稿上方，保留正在输入的文字、光标和普通文本撤销记录。`M-p` / `M-n` 回看已发送消息并恢复原草稿。发送只提交末尾的草稿，不会重复提交整个会话；草稿在成功启动请求后清空，失败则恢复。任务运行期间可起草下一条，发送会提示等待并保留草稿，不自动排队。

`C-c C-k` 取消当前任务，`C-c C-n` 开始新会话；隐藏、新会话和重新打开均保留未发送草稿。未发送文本不进入模型历史，格式化和折叠也只处理已发送记录。

每次问答的中间过程合并到一个默认折叠的区块中，标题简洁显示 `▶ 3 turns · 5 tool calls · 8.2s`，问题和最终回复保持可见。`turns` 是逻辑模型请求轮次，429 和推理状态恢复后的重试不增加 turns；`tool calls` 单独统计实际工具调用（包括失败的调用）。秒数为模型请求累计耗时，包含重试请求耗时，不包含重试前的延迟等待或后台任务时间。展开后可查看每次请求的 `Turn N`、耗时和 HTTP 状态，重试标为 `Turn N · retry K`。每次问答独立计数，历史区块保留各自统计；缺少历史请求数据的旧记录只显示 tool calls，不补猜 turns 或耗时。有失败步骤时标题显示 `failed`，整轮失败或取消提示仍在外面。

在统计标题上按 `TAB`、`RET` 或点击即可展开整轮步骤。相邻 Tool/Result 紧凑排列，不额外留空行。各个 Tool/Result 详情仍可单独展开，JSON 按两空格缩进。在展开的详情中按 `TAB` 可收起当前层，全文搜索命中隐藏内容时会自动展开相应层级。

重新加载插件会自动整理当前已有的会话记录，也可运行 `M-x amble-refresh-display` 手动整理。格式化仅改变日志的显示排版，不删除详情或改变模型会话历史。

## 核心工具与扩展

常驻 13 个工具，按用途分组。工具参数在执行前校验，未知工具或未启用的扩展不会执行。 Lisp 返回值会区分 plist、alist 和普通序列；多个记录保留为数组。重复键的序列不会被强行转换为对象，避免前面的记录被覆盖。

| 分组 | 工具 | 用途 |
|---|---|---|
| 观察 | `emacs_context` | 精简的当前缓冲区、选区、窗口、项目和后台任务；`detailed=true` 展开缓冲区列表 |
| 观察 | `emacs_inspect` | 符号文档、参数、快捷键、mode；变量值需显式 `include_value=true` |
| 观察 | `emacs_search_symbols` | 查找可用函数、命令、变量 |
| 发现 | `emacs_capabilities` | 列出、启用或关闭 Org/ZK/Git 扩展 |
| 读取 | `emacs_find_files` | 在限定目录内查找文件名 |
| 读取 | `emacs_search_text` | 搜索当前缓冲区、打开的缓冲区或项目，优先使用未保存文本 |
| 读取 | `emacs_read` | 按位置、行号或选区读取缓冲区/文件，返回修改版本 `tick` |
| 编辑 | `emacs_edit` | 预览、批量修改、撤销；所有目标先校验版本，不自动保存 |
| 组织 | `emacs_buffers` | 列出、打开、创建、切换、重命名、保存、关闭、清理和恢复缓冲区 |
| 组织 | `emacs_windows` | 显示、聚焦、分屏、调整大小、关闭窗口以及保存/恢复布局 |
| 执行 | `emacs_command` | 调用已查询过的函数，显式传参，拒绝等待 minibuffer 输入 |
| 执行 | `emacs_eval` | 复杂操作的 Elisp 后备入口，尽量返回结构化值 |
| 任务 | `emacs_job` | 启动、查询、等待、取消、列出异步进程 |

在 Org 缓冲区或 Git 工作目录发起任务时，会自动启用对应扩展；其他场景可用 `emacs_capabilities` 启用，下一次模型请求即可使用。新会话会清空已启用扩展，再按当前上下文选择。

- `emacs_org`：发现现有 capture 模板、按模板记录与展示 Org 图片；旧 `add_todo` 入口兼容转发到 zk。
- `emacs_zk`：读取任务、收集待办、创建计划、修改任务状态与日期，以及打开日程。存储与日期逻辑由 zk 提供；加载 zk 后自动启用，也可以手动启用 `zk` 扩展。任务进入 `zk-inbox-file`，计划进入 `zk-agenda-file`；日期仅使用用户指定的精度。
- `emacs_git`：异步获取 Git status/diff 并展示原生输出；用 `emacs_job wait` 等结果。提交、暂存等写操作仍需用户明确要求后通过命令执行。

### 编辑与保存

读取结果返回缓冲区名、`tick`、起止位置和截断信息。位置从 1 开始、end 不包含在范围内；行号从 1 开始且包含 end_line。插入使用相同 start/end，删除使用空 text。

`emacs_edit` 的 changes 是缓冲区变更列表，每项指定 buffer 或 file、expected_tick，以及 edits 数组。所有位置都基于修改前的文本。版本过期、范围非法或区间重叠时拒绝整批操作；正文变更以 Emacs change group 保护，失败会回滚这批文本修改。预览展示 before/after，不改目标文本。跨缓冲区修改分别保留各缓冲区的撤销记录。

保存是独立的 `emacs_buffers save` 操作，需要当前 expected_tick；同时检查文件是否被外部修改。新文件需要明确 destination，不覆盖现有路径。关闭不丢弃未保存内容或运行进程，重命名只改变缓冲区名称。窗口操作不杀掉缓冲区。

### 搜索与后台任务

原生文件遍历跳过符号链接、隐藏目录（除非显式打开）及常见生成目录，受深度、条目数和耗时限制。项目搜索跳过超过 512 KiB 的未打开文件及检测到的二进制文件。截断和跳过结果会明确返回，请缩小范围或用后台任务运行外部搜索。`emacs_read` 默认最多返回 16000 字符，可分页；未打开的文件超过 2 MiB 时需要先显式打开。

`emacs_job start` 接收 `[program, arg1, ...]`，不隐式经过 shell；需要 shell 语法时必须显式选择 shell。任务有 ID、状态、退出码和分页输出，最多并发 4 个，默认 120 秒超时。输出最多保留 128 KiB，超限会标记。进程输出显示在原生缓冲区，不弹出 message。

`wait` 会暂停模型循环，进程完成后自动追加对应工具结果并继续，不阻塞 Emacs、不消耗请求轮询。等待期间 `C-g` 会停止当前等待的任务；独立运行且未被等待的后台任务可用 `cancel` 按 ID 终止。网络重试复用工具结果，不重新启动已有任务。

## 接入协议

默认基础地址为 `https://aidp.bytedance.net/api/modelhub/online`。Amble 自动追加 `/responses`，实际发送 `POST https://aidp.bytedance.net/api/modelhub/online/responses`；也接受已经包含 `/responses` 的完整地址。

认证使用 `Authorization: Bearer <API key>` 请求头。密钥仅从 `EMACS_AMBLE_API_KEY` 读取，不会添加到 URL。请求关闭 URL 历史、缓存、调试输出和 Cookie，不自动跟随重定向；诊断信息会隐藏密钥，临时请求缓冲区在完成、失败、超时或取消时释放。

请求采用 Responses 格式：

- `input`：完整会话，包括用户消息、模型输出及工具结果。
- `tools`：平铺的 `type`、`name`、`description`、`parameters` 字段。使用 `strict: false` 保持现有工具的可选参数语义。
- `tool_choice: "auto"`：模型可以直接回答，也可以请求工具。
- `reasoning: {"effort":"medium","summary":"auto"}`：分别由 `amble-reasoning-effort` 和 `amble-reasoning-summary` 控制。
- `max_output_tokens`：由 `amble-max-tokens` 控制，包含推理与可见输出 token。
- `store: false`：会话由 Emacs 在内存中维护，并请求 `reasoning.encrypted_content` 以支持无服务端会话存储的后续请求。

每次响应的完整 `output` 都会保留，包括不透明的 reasoning 项。工具请求取自 `function_call`；执行后发送对应 `call_id` 的 `function_call_output`。普通回答从 `message` 中的 `output_text` 提取。只有完整、有效的响应才能触发工具；失败、截断和非法参数结构会直接报错。

GPT-6 Astra 的工具调用使用 Responses API，参见 [OpenAI function calling 文档](https://developers.openai.com/api/docs/guides/function-calling)。

当前仍使用异步、非流式 HTTP；每一步完成后更新进度。工具执行安排在网络回调之外。`C-g` 会终止连接并丢弃尚未交付的结果，旧请求不能影响新任务。超时按每次 HTTP 请求计算。仅当 HTTP 400 明确返回 `invalid_encrypted_content` 时，会删除当前请求中的 reasoning 项并重试一次；用户消息、助手正文、函数调用及对应工具结果原样保留。恢复只重发模型请求，不重新执行已有工具；无法复用的隐藏推理会丢失，但模型仍可根据会话和工具结果继续推理。恢复说明显示在折叠的执行过程中，不弹出 message。HTTP 429 会按下面的策略延迟重试；其他错误不自动重试。重启 Emacs 后会话历史不自动恢复。

### 资源不足与限流

HTTP 429 默认等待 5、10、20 秒，最多额外重试 3 次，每次只重发当前模型请求，保留已有工具结果。若服务端提供 `Retry-After`（秒数或 HTTP 日期），会至少等待指定时间；单次等待超过 60 秒则停止自动重试，不提前请求。每次网络请求单独计算 `amble-http-timeout`，次数上限不会被推理状态恢复重置。

重试期间状态栏显示“等待重试”，具体次数和等待时间写入折叠的执行过程，不弹出 `message`。`C-g` 可取消网络请求和等待中的重试。超过次数上限时保留当前对话，显示简短错误。

`amble-rate-limit-retries` 控制额外重试次数，范围 0–10，默认 3；设为 0 可关闭。ModelHub 的 `-2004` 表示业务资源不足，若持续发生，需要通过平台申请扩容或稍后再试，客户端重试不能增加配额。

## 数据与执行范围

自动上下文默认只包含当前 buffer 元数据、选区边界、窗口、项目、已启用扩展和运行中的任务，**不包含正文或全部缓冲区列表**。模型按需调用读取工具获取文本。运行 `amble-context` 可以预览自动上下文。

可以过滤自动上下文，例如仅包含某个项目：

```elisp
(setq amble-context-buffer-predicate
      (lambda (buffer)
        (with-current-buffer buffer
          (and buffer-file-name
               (file-in-directory-p buffer-file-name "/path/to/project/")))))
```

这是上下文过滤器，**不是权限沙箱**。`emacs_eval` 和 `emacs_command` 拥有当前 Emacs 进程的完整权限；通用控制能力意味着它们可调用文件、进程和其他包的接口。插件没有为任意 Lisp 提供可靠的分类审批或回滚。默认指令要求按用户意图行动、保护未保存内容、将文件内容视为数据，并在无关破坏性或外部动作前询问。

便捷清理工具保留修改过、可见、带进程和当前任务使用的 buffer，并尊重 kill hooks。普通文件 buffer 可重新打开；无文件且无修改的临时 buffer 内容不能自动恢复。计时从启用插件开始，默认 60 分钟。

Lisp 操作在 Emacs 主线程执行。15 秒超时是协作式的，不能强行打断 CPU 死循环或阻塞的原生调用；普通可中断 Lisp 可用 `C-g` 停止。对 minibuffer 的无人值守多步交互尚未封装，agent 优先使用函数的非交互参数。不会自动导出 Org 或执行 Babel；需要用户明确要求。

## 对话与工具循环

聊天和操作共享同一份会话历史，不需要手动切换模式。一般概念解释直接回答；涉及真实编辑器状态时读取工具，明确要求修改时才执行操作。Responses API 使用 `tool_choice: "auto"`，允许模型选择文字回复或工具调用。

模型返回文字时直接展示；返回工具调用时，先校验调用结构，再由 Emacs 执行，将结果追加到会话中交回模型。模型可继续调用工具或给出最终回复。完整的响应项与工具调用结果按顺序保留，支持推理上下文和多轮工具调用。

结构参考 Codex 的对话轮次、工具分发和取消机制，底层直接使用 ModelHub 的 Responses API。

## 文件

- `amble.el`：模型配置、系统指令、上下文、对话循环和取消。
- `amble-display.el`：会话渲染、折叠、JSON 排版和统计显示。
- `amble-frame.el`：单窗格浮动会话、工作 frame 关联和焦点管理。
- `amble-input.el`：按键隔离、会话末尾草稿、发送、输入历史和异步输出期间的草稿保护。
- `amble-modelhub.el`：原生异步 HTTPS、Responses 输出解析、超时、错误脱敏。
- `amble-tools.el`：工具注册、参数校验、能力发现、观察与高级执行。
- `amble-core.el`：共享配置、目标解析、结构化返回和输入限制。
- `amble-files.el`：文件发现、文本搜索与读取。
- `amble-edit.el`：版本检查、预览、批量编辑和撤销。
- `amble-workspace.el`：缓冲区与窗口管理。
- `amble-jobs.el`：异步任务与完成通知。
- `amble-org.el`、`amble-git.el`：按需加载的扩展。

更新后重启 Emacs，加载新代码并开始新会话。

## ZK 联动测试

在已安装 zk 的环境中，从 Amble 仓库运行：

```sh
emacs -Q --batch -L . -L ~/.emacs.d/elpa/zk -l tests/amble-zk-tests.el -f ert-run-tests-batch-and-exit
```

测试使用临时知识库，不调用模型或修改真实笔记。
