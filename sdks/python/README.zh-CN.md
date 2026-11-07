# Fyrlet Python SDK

[English](README.md) | 简体中文

同步、基于线程的客户端，提供类型化业务调用和可恢复的实时订阅。遵循[协议](../../docs/PROTOCOL.md)，语义与 [TypeScript SDK](../typescript/README.zh-CN.md) 一致。包尚未发布，可用 `pip install -e sdks/python` 本地安装。需要 Python 3.10+，仅依赖 `websockets`（HTTP 使用标准库）。

## 在后端交换会话

```python
from fyrlet import SessionService

sessions = SessionService(os.environ["FYRLET_ENDPOINT"], os.environ["FYRLET_SERVICE_KEY"])
session = sessions.issue_session(authenticated_user.id, issuer="my-product", ttl_seconds=600)
# 只把 session.token 返回给该用户；service key 只留在后端。
sessions.revoke_session(session.session_id)
```

`authenticated_user` 必须来自应用已验证的登录状态。

## 调用与重试

```python
from fyrlet import Client, ApiError, OutcomeUnknownError

client = Client(endpoint, project_id, get_token)   # get_token(force_refresh: bool) -> "rts_..."

item = client.call("inbox.add", {"text": "Hello"}, idempotency_key=stable_request_id)
client.call("inbox.update", {"id": item["id"], "text": "Updated", "expected_version": item["version"]})
```

- 首次认证会读取身份并绑定 Subject；同一客户端切换账号会以 `FORBIDDEN` 拒绝，请关闭后新建客户端。
- SDK 为每次调用生成幂等键，登录过期时最多刷新一次 token 并复用该键。`CONFLICT` 不会自动重试。宿主登录已失效时，让 `get_token(True)` 抛出 `ApiError("UNAUTHENTICATED", ...)` 以终止恢复。
- `ApiError` 提供 `code`、`message`、`details`、`retryable`、`status` 和 `request_id`。请求默认 10 秒超时（`timeout=`）。
- 写请求已发出但结果丢失时，`call` 抛出 `OutcomeUnknownError`（带 `operation` 和 `idempotency_key`）。不要盲目重发，先向服务端查询。

```python
mutation = client.mutate("inbox.add", {"text": "Hello"})   # 操作失败时不抛异常
mutation.state.status        # completed | committed | accepted | failed | unknown
if mutation.state.status == "unknown":
    mutation.recover()       # 查询已存储的回执，绝不再次执行
client.recover("inbox.add", {"text": "Hello"}, idempotency_key=key)   # 用已保存的键查询
```

`recover` 返回带原始结果的 `committed`/`accepted`，或在看不到回执时返回 `unknown`。详见[操作结果与恢复](../../docs/MUTATIONS.md)。

## 订阅

```python
recent = client.subscribe("inbox.recent", {"limit": 20})
stop = recent.on_change(lambda state: render(state.status, state.data, state.error))
recent.refresh()        # 服务端接受后返回；数据通过 on_change 到达
stop(); recent.unsubscribe(); client.close()   # 或：with Client(...) as client:
```

`on_change` 会立即交付当前状态，随后交付每次变化，由专用分发线程回调，因此监听器可以安全地回调客户端。状态为 `connecting`、`ready`、`recovering`（保留旧数据）、`error` 和 `closed`（清空数据）。`generation` 与 `seq` 用于拒绝过期消息。

SDK 默认请求 `delta-v1`（`delta=False` 则只要完整快照），确认每个快照和增量，并在断线、序号缺口或服务端返回可重试状态后，以 250 ms 到 30 s 的指数退避重建连接（可用 `retry_delay=` 覆盖）。未确认的写入不会重放。终止性的认证和权限错误会清空数据并使订阅进入 `error`。视图按不可变处理：增量会创建新容器，不修改已交付的值，所以不要修改 `state.data`，需要时先复制。

## 范围

已实现：会话服务、基于 HTTP 的业务调用、身份绑定、token 刷新、幂等、结果未知后的恢复、契约导出，以及带快照/增量/ACK/refresh/恢复的订阅。尚未实现（TypeScript SDK 已有）：Run、append 订阅、presence、乐观写入、业务调用的 Socket RPC 和契约类型生成。

## 测试

```bash
pip install -e 'sdks/python[test]'
pytest sdks/python/tests/test_units.py        # 离线
scripts/integration_sdks.sh python            # 启动 inbox 示例服务并运行全部测试
```
