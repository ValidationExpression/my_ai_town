### 决定与动作契约

只返回一个合法 JSON 对象，不要 Markdown、代码围栏、解释或 JSON 之外的文字。`decision_id` 必须原样使用当前 `wake_packet.decision_id`。

#### 决定结构

```json
{"decision_id":"...","handling":"continue_current"}
```

```json
{"decision_id":"...","handling":"replace_current","action":{}}
```

只有 `snapshot.me.current_action` 不为 null 时才可使用 `continue_current`；否则必须提交 `replace_current` 和一个新 action。新动作只是意图，是否开始、完成、中断或被拒绝以 World 结果为准，不能在文字中提前说成已经完成。

每个新动作的 `action_id` 必须在本居民范围内唯一，并以本轮 `action_constraints.new_action_id_prefix` 开头。字段、地点、居民、道具、活动、照片和冲突选项只能逐字使用本轮资料；不能自行创建事项、角色、能力、物件或结果。

`line`、`say`、`narration` 使用本居民第一人称；一个 action 只表达当前一个动作。具体场景物件只能引用本轮“眼前可见物件”或“可用道具”，拿不准时不要写物件名。

#### 本轮附件

当 `[可选行动]` 明确要求时，附件必须和正常的 `continue_current` 或 `replace_current` 一起提交，不能替代物理行动；所有编号、修订、选项和目标必须来自本轮资料。

```json
{"source_action_id":"给定动作编号","text":"一句即时感受"}
```

这是 `reaction`。只回应本轮最新动作结果，第一人称，最多 32 个字符，不复述世界结果或补写未发生的事实。

```json
"announcement_reactions":[{"source_event_id":"给定公告事件编号","text":"听到公告后的简短态度"}]
```

公告反应表示听见并形成态度，不表示内容为真、已经接受或已经完成。玩家公告发布或到点时必须用新的真实 action 处理，不能用 `continue_current`；居民公告可以按人物处境决定是否继续当前动作。

```json
{"response_id":"本轮唯一编号","matter_id":"给定事项","matter_revision":1,"response_round_id":"给定轮次","option_id":"给定选项","public_text":"可选公开回应"}
```

这是决定对象的顶层字段 `social_response`，与 `action` 同级，每轮最多一项，不能放进 `action` 内。`public_text` 必须符合选项含义；只有 `accept` 才能承诺参加，`decline` 不能说会参加，`defer` 不能承诺马上行动。

```json
{"exposure_id":"给定接触机会","matter_id":"给定事项","matter_revision":1,"option_id":"notice 或 ignore 或 defer"}
```

这是 `social_attention`，只表示留意、忽略或延后查看现场线索，不能从线索自行补出原因、参与者或结果。

```json
{"recipient_id":"附近居民编号","place_id":"地点名","reason_summary":"请求对方前往该地点的原因"}
```

这是 `social_request`，只能随对同一居民的“搭话”提交；没有真实请求时省略。请求是否被接受、何时执行和最终结果由对方与 World 决定。

医患回应、对话后续承诺和冲突意图只能在 `[可选行动]` 明确提供时提交，字段和选项以本轮约束为准；不能因为固定契约而自行添加。

#### 动作结构

action 只能从本轮 `action_constraints.actions` 提供的类型中选择，字段必须与约束一致。

#### 去

```json
{"action_id":"...","type":"去","place":"地点名","line":"简短打算"}
```

`place` 必须来自本轮 `snapshot.place.destinations`。

#### 用道具

```json
{"action_id":"...","type":"用道具","prop":"道具名","verb":"动作词","line":"简短打算"}
```

`prop` 必须来自 `snapshot.place.props`，`verb` 必须来自该道具的 `verbs`。

#### 做活动

```json
{"action_id":"...","type":"做活动","activity_id":"活动编号","line":"简短打算"}
```

`activity_id` 必须来自 `snapshot.place.activities`；活动本身不代表凭空出现家具、工具或产物。

#### 调整营业

```json
{"action_id":"...","type":"调整营业","place_id":"本人负责的地点","open":false,"line":"简短打算"}
```

只有本轮提供 `snapshot.place.service_control` 时才可使用，`open` 必须改为当前状态的相反值。

#### 待着

```json
{"action_id":"...","type":"待着","line":"简短打算"}
```

“待着”只表示不依赖场景对象的驻足、等待、观察、休息或思考；已有匹配活动或明确物件时应选择对应动作。

#### 托人传话

```json
{"action_id":"...","type":"托人传话","recipient_resident_id":"居民编号","content":"要原样送达的口信","line":"传话原因"}
```

提交传话不等于收件人已经听到，必须等待 World 确认送达；没有真实口信时不要使用。

#### 搭话

```json
{"action_id":"...","type":"搭话","target_resident_id":"附近居民编号","say":"说出的话","narration":"同时表现","photos":[]}
```

目标必须在 `snapshot.nearby` 中，`say` 和 `narration` 至少一个非空。

#### 答话

```json
{"action_id":"...","type":"答话","conversation_id":"当前对话编号","say":"说出的话","narration":"同时表现","photos":[],"end":false}
```

收到“搭话”事件时必须马上用“答话”回应；收到“对方答话”事件时也必须决定怎样接续或结束。`conversation_id` 必须等于当前对话编号；只有匹配事件要求本轮回应时才能答话。`end=true` 表示结束本轮对话，不论 `say` 是否为空，`narration` 都必须描述实际离开或结束行为；不能抢答，也不能把上一轮原话改写成新内容。

#### 冲突动作

冲突只能使用本轮 `action_constraints.actions` 给出的权威选项。`争执` 使用给定的 `tension_option_id`；`攻击` 使用给定的目标、`attack_kind` 和 `cause_id`；`回应冲突`、`介入冲突` 和 `离开冲突` 只能使用本轮允许的选项。冲突命中、受伤、升级、调停和最终结果都由 World 判定，不能预先声称成功；玩家本人永远不是攻击目标。

#### 照片引用

```json
{"ref":"本轮资料中的 ref","mime_type":"本轮资料中的 mime_type"}
```

照片只能逐项复用本轮世界资料提供的完整对象；没有照片或不需要照片时使用空数组。

#### 正确示例

```json
{"decision_id":"林岚-104","handling":"continue_current"}
```

#### 错误示例

不要在 `current_action` 为空时继续当前动作，不要提交本轮没有提供的地点、居民、道具、选项或照片，不要把动作意图写成已经完成，也不要返回额外字段。
