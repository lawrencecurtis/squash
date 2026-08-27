# 🤖 squash

An AI-powered Git utility that intelligently groups your commits and rewrites their messages using a local LLM (Ollama).

**DOES NOT TOUCH YOUR CODE just your git history.**

Perfect for developers who make frequent `git commit -am "wip"` commits throughout the day and want an automated way to clean up their git history into logical, well-documented chunks.

## ✨ Features

- **🧠 Smart Clustering:** Analyzes your commit history and files changed to group related commits together automatically.
- **✍️ AI Commit Messages:** Generates high-quality, standardized commit messages based on the unified diff using a local Ollama model.
- **🪄 Auto-WIP Detection:** Automatically finds your oldest "wip" commit and starts the smart-squash process from there.
- **⌨️ Interactive TUI:** Fuzzy-find your base commit using `fzf`.
- **📦 Single File:** Easy to edit and customize. No compilation required.

## 📋 Prerequisites

To use `squash`, you need the following CLI tools installed:

- `git`
- `fzf` (for the interactive TUI)
- `jq` (for JSON parsing)
- `curl` (for API requests)
- [Ollama](https://ollama.com/) running locally with the `gemma4:12b-mlx` model (or update the script to use your preferred model like `llama3` or `mistral`).

## 🚀 Installation

1. Download the script:

```bash
curl -O squash [https://raw.githubusercontent.com/lawrencecurtis/squash/main/squash.sh](https://raw.githubusercontent.com/lawrencecurtis/squash/main/squash.sh)
```

2. Make it executable:

```bash
chmod +x squash
```

3. **Move it to a directory in your `$PATH`.** On macOS/Linux, you have two standard options:
   **Option A: System-wide (Easiest)**
   `/usr/local/bin` is usually in your path by default, but requires admin privileges.

```bash
sudo mv squash /usr/local/bin/squash
```

**Option B: User-only (Best Practice)**
Keep it isolated to your user account without needing `sudo`.

```bash
mkdir -p ~/.local/bin
mv squash ~/.local/bin/squash
```

_Note: If you use Option B, ensure `~/.local/bin` is in your `$PATH`. You can add it (assuming you use Zsh, the Mac default) by running:_

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## 🛠️ Usage

`squash` can be run in three different ways depending on your workflow:

### 1. Interactive TUI (Default)

Simply run `squash` without any arguments. It will open an `fzf` prompt showing your git log. Select the base commit (the commit _before_ your changes began) to start the smart rebase.

```bash
squash
```

### 2. Auto-WIP Mode

If you consistently use "wip" (or "WIP") in your temporary commit messages, run `squash --wip` (or `squash auto`). The script will find the oldest WIP commit in your current branch and automatically use its parent as the base.

```bash
squash --wip
```

### 3. Manual Mode

Pass a specific commit hash or reference (like `HEAD~5`) directly to the script.

```bash
squash HEAD~5
```

## ⚙️ Customization

`squash` is designed to be easily hackable. Open the script in your favorite editor to customize:

- **The LLM Model:** Change the `MODEL="gemma4:12b-mlx"` variable at the top of the script.
- **Commit Message Style:** Edit the `SYSTEM_PROMPT` in **PHASE 1** to change how the AI writes your commit messages.
- **Clustering Logic:** Edit the `SYSTEM_PROMPT` in **PHASE 2** to change how the AI decides to group commits.

## 🤝 Contributing

Pull requests are welcome! If you have ideas for improvements or find any bugs, please open an issue or PR.
