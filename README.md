# Bash is all you need

The most basic AI agent in a tiny bash file (< 500 loc) with only one tool: bash.

## DANGER

- LLMs can make mistakes, misunderstand prompts, or generate unsafe/wrong shell commands.
- Commands can delete files, leak secrets, modify your system, or cause data loss.
- Always review every command before running it, and never run this against systems/data you cannot afford to lose.
- This project is provided **as is**, at your own risk.
- I am not responsible for any damage, data loss, security issues, or other consequences from using this tool.


## What it does

The agent sends your task to the OpenAI Responses API, lets the model decide which shell command to run, asks you for approval (unless disabled), executes the command, returns output to the model, and repeats until done.

## Requirements

- Bash
- `curl`
- `jq`
- `OPENAI_API_KEY` set in your environment

## Usage

### With curl

```
export OPENAI_API_KEY="your_api_key"

curl https://mistake.sh | bash -s -- "create nodejs project"
```

### Locally

Install

```bash
curl https://raw.githubusercontent.com/mpowaga/no-mistake/refs/heads/main/no-mistake.sh -o no-mistake.sh
```

```bash
chmod +x mistake.sh
export OPENAI_API_KEY="your_api_key"

./no-mistake.sh "summarize this repo"
```

You can also pipe input:

```bash
./no-mistake.sh < TASK.md
```

## Options

```text
-m, --model MODEL          OpenAI model (default: gpt-4.1-mini)
-s, --max-steps N          Max command steps (default: 50)
-A, --accept-mistakes      Skip per-command approval
-h, --help                 Show help
```


