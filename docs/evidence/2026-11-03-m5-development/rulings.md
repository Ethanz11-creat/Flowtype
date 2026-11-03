# M5 三项去重裁决及代价

以下仅合并A/B安全staging与当前C progress中重复出现的既有裁决，没有新增实现范围。

| 裁决 | 依据与适用范围 | 若判断错误的代价及限制 |
| --- | --- | --- |
| 复用一名implementer，controller分别完成逐任务、限定范围及最终审查 | 用户最多一个子智能体的约束优先于skill默认的每任务新implementer/reviewer；按书面brief、diff及review gate执行 | 新上下文视角减少；以逐任务书面审查和全M5独立源码/实际技术复核缓解 |
| 原planning-only句子为历史轮次，后续明确实施授权已取代其实施限制 | 用户已要求开发完整M5 A→B→C；保留历史规划记录，继续遵守不push、不安装、不读取真实用户数据 | 可逆源码/文档修改；无外部发布副作用，未扩展为权限、真实数据或服务操作授权 |
| C3额外接收明确预期appPath及独立source identity | B3 manifest无appPath；CI身份独立于artifact成功。不能信任报告自己的路径自证身份，也不能因artifact缺失绕过CI身份校验 | 可逆的内部验证helper API/计划调整；不改变产品流程，不引入外部验收副作用 |

出处：[A进度](a/progress.md)、[B进度](b/progress.md)、[C进度](c/progress.md)。当前结果及边界见[索引](README.md)；41项人工和远端CI Pending。
