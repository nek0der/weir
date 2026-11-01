// site.ts
// Weir — what the site says and where it points: its addresses, languages, and every word of the landing page and the top bar.
// Words carry `<wbr>` between Japanese phrases, so the page writes them as HTML.

export const REPO_URL = "https://github.com/nek0der/weir";
export const DOWNLOAD_URL = `${REPO_URL}/releases/latest`;
export const LANG_STORAGE_KEY = "weir-lang";
export const THEME_STORAGE_KEY = "starlight-theme";

export const LANGS = [
  { code: "en", name: "English", prefix: "" },
  { code: "ja", name: "日本語", prefix: "/ja" },
] as const;
export type Lang = (typeof LANGS)[number]["code"];

export function prefixOf(lang: Lang): string {
  return LANGS.find((l) => l.code === lang)?.prefix ?? "";
}
export function homeOf(lang: Lang): string {
  return `${prefixOf(lang)}/`;
}
export function docsOf(lang: Lang): string {
  return `${prefixOf(lang)}/docs/`;
}

export const STRINGS = {
  en: {
    title: "Weir: a Mac window for reviewing what Claude Code and Codex change",
    description: "A native Mac window for Claude Code and Codex. See which one needs you and what each turn changed.",
    locale: "en_US",
    operatingSystem: "macOS 26 or later",
    imageAlt: "A Weir window: worktrees on the left, a terminal in the middle, each turn's changes on the right.",
    product: "Product",
    docs: "Docs",
    download: "Download",
    downloadForMac: "Download for Mac",
    viewOnGitHub: "View on GitHub",
    language: "Language",
    toDark: "Switch to dark",
    toLight: "Switch to light",
    heroTitle: "Review at the speed<br>of your agents.",
    heroBody: "A native Mac window for Claude Code and Codex. See which one needs you and what each turn changed.",
    captions: [
      ["Every agent, in one window.", "Real terminals in the middle. What needs you on the left. What changed on the right."],
      ["Know who is waiting.", "Approvals, questions, stops, and unviewed turns, across every project. ⌘J goes to the next one."],
      ["Every project at a glance.", "Worktrees sorted by what needs you, what is running, and what is idle, with a filter and each terminal's last lines."],
      ["See what each turn changed.", "Weir snapshots the worktree around each turn, so you can review it or restore the code to before it."],
      ["Read the diff, and answer it.", "Comment on any line, then insert your comments into the agent's prompt."],
      ["Decide, and keep going.", "The decision bar sums up what you have not viewed, with the last test run beside it."],
    ],
    quietTitle: "It is not an editor.<br>It is not an agent.",
    quietBody: "Claude Code and Codex keep their own terminal UI, and you still type in their prompts.",
    specs: [
      ["Agents", "Claude Code, Codex, Antigravity"],
      ["Terminal", "libghostty"],
      ["Requires", "macOS 26 or later, Apple Silicon"],
      ["License", "MIT"],
    ],
    endTitle: "Try it on your next task.",
    notFoundTitle: "Nothing flows here.",
    notFoundLink: "Back to Weir",
  },
  ja: {
    title: "Weir: Claude Code と Codex の変更をレビューする Mac アプリ",
    description: "Claude Code と Codex を並行して動かす人のための Mac アプリ。どれが待っているか、各ターンで何が変わったかがすぐ分かります。",
    locale: "ja_JP",
    operatingSystem: "macOS 26 以降",
    imageAlt: "Weir のウィンドウ。左にワークツリー、中央にターミナル、右に各ターンの変更。",
    product: "製品",
    docs: "ドキュメント",
    download: "ダウンロード",
    downloadForMac: "Mac 版をダウンロード",
    viewOnGitHub: "GitHub を見る",
    language: "言語",
    toDark: "ダークに切り替える",
    toLight: "ライトに切り替える",
    heroTitle: "エージェントの<wbr>速さに、<br>レビューが<wbr>追いつく。",
    heroBody: "Claude Code と Codex を<wbr>並行して<wbr>動かす人の<wbr>ための Mac アプリ。<br>どれが<wbr>待っているか、<wbr>各ターンで<wbr>何が<wbr>変わったかが<wbr>すぐ分かります。",
    captions: [
      ["すべての<wbr>エージェントを、<wbr>ひとつの<wbr>画面で。", "中央は<wbr>本物の<wbr>ターミナル。<br>左に<wbr>対応が<wbr>必要な<wbr>もの、<wbr>右に<wbr>変更の<wbr>一覧。"],
      ["いま誰が<wbr>待っているか、<wbr>すぐ分かる。", "プロジェクトを<wbr>またいで、<wbr>承認、<wbr>質問、<wbr>停止、<wbr>未確認の<wbr>ターンを<wbr>一覧に。<br>⌘J で<wbr>次へ<wbr>移動できます。"],
      ["すべての<wbr>プロジェクトを、<wbr>一度に<wbr>見渡す。", "要対応、<wbr>実行中、<wbr>待機中に<wbr>分けて<wbr>一覧に。<br>ここで<wbr>絞り込みが<wbr>でき、<wbr>各ターミナルの<wbr>直近の<wbr>出力も<wbr>見られます。"],
      ["ターンごとの<wbr>変更を、<wbr>あとから<wbr>追える。", "ターンの<wbr>前後を<wbr>記録するので、<wbr>変更を<wbr>確認でき、<wbr>気に入らなければ<wbr>ターン前の<wbr>コードに<wbr>戻せます。"],
      ["差分を<wbr>読んで、<wbr>コメントを<wbr>返す。", "気になる<wbr>行に<wbr>コメントを<wbr>残し、<wbr>まとめて<wbr>エージェントの<wbr>プロンプトに<wbr>入れられます。"],
      ["確認したら、<wbr>そのまま<wbr>次へ。", "未確認の<wbr>変更と<wbr>直近の<wbr>テスト結果を、<wbr>判断バーに<wbr>まとめて<wbr>表示します。"],
    ],
    quietTitle: "エディタでも、<wbr>エージェントでも<wbr>ありません。",
    quietBody: "Claude Code と Codex は<wbr>いつもの<wbr>ターミナル&nbsp;UI&nbsp;のまま。<br>指示も<wbr>これまでどおり<wbr>エージェントの<wbr>プロンプトに<wbr>入力します。",
    specs: [
      ["対応エージェント", "Claude Code, Codex, Antigravity"],
      ["ターミナル", "libghostty"],
      ["動作環境", "macOS 26 以降、Apple Silicon"],
      ["ライセンス", "MIT"],
    ],
    endTitle: "まずは<wbr>次のタスクから。",
    notFoundTitle: "この先には、<wbr>何もありません。",
    notFoundLink: "Weir のトップへ",
  },
} satisfies Record<Lang, Record<string, unknown>>;
