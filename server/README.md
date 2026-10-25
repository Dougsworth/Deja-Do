# Deja Do server

Holds the AI keys so testers don't need their own. The app sends its "which element is it?" question here with an access code, and the server forwards it to Anthropic, OpenAI or Google with your key, depending on the model picked.

- Each person gets their own access code, so you can see who uses what and cut anyone off.
- Each person has a daily limit (200 by default) so nobody runs up the bill.
- Only who, which model, status and timing are logged. Never the question or the answer.

## Deploy on Dokploy

1. **Create an Application** from the `Dougsworth/Deja-Do` GitHub repo, branch `main` (or `vision-and-step-checks` until it's merged).
2. **Build:** type Dockerfile, build path `server`, Dockerfile path `Dockerfile`.
3. **Environment:**

   ```
   ACCESS_CODES=douglas=PASTE_A_CODE,jason=PASTE_ANOTHER
   ANTHROPIC_API_KEY=sk-ant-...
   OPENAI_API_KEY=sk-...
   GEMINI_API_KEY=AIza...
   DAILY_LIMIT=200
   ADMIN_CODE=PASTE_A_CODE
   ```

   Leave out any key you don't have; those models just say they aren't set up. Make each code with `openssl rand -hex 16`. Codes shorter than 12 characters are ignored.
   Optional: `ALLOWED_MODELS=claude-haiku-5-5,gpt-6-luna` to offer only cheap models.
4. **Volume:** add a volume mount (named volume) at `/data`. That's where the daily counts live.
5. **Domain:** add one, e.g. `ai.yourdomain.com`, port `3000`, HTTPS on.
6. **Deploy**, then check `https://ai.yourdomain.com/health` says `{"ok":true}`.

## Point the app at it

Either type the address into Settings › AI service › Deja Do on each Mac, or build it in so testers only need their code: put the address in `Support/Info.plist` under `DejaDoServerURL`, then `./build.sh release`.

## Endpoints

| | |
| --- | --- |
| `GET /health` | Up or not |
| `GET /v1/me` | Your name and how many fixes you've used today (access code) |
| `POST /v1/choose` | `{model, system, prompt, maxTokens}` → `{text}` (access code) |
| `GET /v1/usage` | Last 7 days per person and model (admin code) |

## Develop

```bash
cd server
bun test
ACCESS_CODES=me=local-test-code-1 ANTHROPIC_API_KEY=sk-ant-... DATA_DIR=./data bun src/index.ts
```
