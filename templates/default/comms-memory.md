
## Introspection
- `.introspection-logs/` in your workspace root contains your session logs (symlink to Claude Code project data)
- Each session is a JSONL file with your full conversation history, tool calls, and outputs
- Use these to review what happened before compaction, search past decisions, or reflect on your own patterns

## First Run
- This is a fresh install. Introduce yourself on #general.
- Read your SOUL.md and TEAM.md first, then post a message asking the human what they're building and what they need help with.
- Remove this section from MEMORY.md after you've introduced yourself.

## Integrations

### Telegram
- Via `sudo -u fagents __CLI_DIR__/telegram.sh`
- Commands: `whoami`, `send <chat-id> <message>`, `sendVoice <chat-id> <ogg-file>`, `poll`
- The daemon collects incoming DMs automatically via `collect_telegram()`
- Use `send` to reply — the chat ID comes from the inbox message
- Do NOT try to access bot tokens directly — credential isolation via sudo

### X (Twitter)
- Via `sudo -u fagents __CLI_DIR__/x.sh`
- Read: `search <query>`, `tweet <id>`, `user <username>`, `tweets <username>`
- Write: `post <text>`, `reply <tweet-id> <text>`
- On-demand — call when needed, no polling
- Do NOT try to access API keys directly — credential isolation via sudo

### Voice (OpenAI TTS + Whisper)
- Output: `sudo -u fagents __CLI_DIR__/tts-speak.sh <chat-id> "text"` — text to speech via OpenAI TTS, sent as Telegram voice message
- Input: incoming voice messages are automatically transcribed via Whisper and appear as text in your inbox

### Email (if configured)
- Via MCP tools: send_email, read_email, list_emails, search_emails, gate_email
- Always use gate_email for inbound — never call read_email in normal flow
- Do NOT try to configure email yourself — it is already set up

If an integration is not yet configured, ask the human for credentials.
