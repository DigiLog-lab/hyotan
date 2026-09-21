# 名前の由来 / Why "Hyotan"

## 瓢箪から駒

**Hyotan**(瓢箪、ひょうたん)は、ことわざ「瓢箪から駒」から取った。

瓢箪は、腰に下げて持ち歩く小さな器。駒は馬。手のひらに載る器の口から馬が
飛び出してくる——起こるはずのないことが、実際に起きること、を言う。

このプロジェクトがやっているのは、iPhone のアプリの**中で** ARM64 Linux の
ユーザーランドを動かし、その中でコーディングエージェント(Codex)に仕事を
させることだ。JIT は使えない、fork も exec もない、サンドボックスの外には
出られない。従来の常識では「できない」で片づけられていた。それが、ポケットの
中の器で起きている。瓢箪から駒、そのままである。

## なぜ「不可能」の言葉なのに、これなのか

日本語で不可能を言う言葉の多くは「だから無い」「だから無駄だ」で終わる。
絵に描いた餅、机上の空論、兎角亀毛、逃げ水、蜃気楼。どれも、無いものの喩えだ。

このプロジェクトは実在して、動いている。だから選ぶ言葉は「無い」側ではなく
「ありえないのに、起きた」側でなければならない。瓢箪から駒は、その数少ない
ひとつである。

## 壺中の天地

もうひとつ、重ねている故事がある。「壺中天」——市場の薬売りが店先に吊るした
壺(瓢とも伝わる)に入ると、その中にもうひとつの天地が広がっていた、という
『後漢書』の話だ。

小さな器の中に、世界が丸ごとひとつ入っている。iPhone の中の Linux は、
技術的にはこちらの絵のほうが正確かもしれない。瓢箪は名前に、壺中天は
その中身の説明に使う。

> 瓢箪から駒。壺中に天地あり。

## Linux ディストリビューション「風」

中身の rootfs は Alpine Linux で、Hyotan 自身はディストリビューションではない。
カーネルも無い(iSH 由来のシステムコール変換層があるだけだ)。それでも
"Hyotan Linux" と名乗るのは、短い一語に Linux を添える、あの界隈の名付けの
作法——Alpine, Arch, Void, Asahi——に連なりたかったからである。

## In English

*Hyōtan kara koma* (瓢箪から駒) — "a horse out of a gourd" — is a Japanese idiom
for something that cannot happen, happening anyway. A *hyōtan* is a small gourd
flask carried at the waist.

Running a Linux userland, and a coding agent inside it, *inside* an iOS app
process was supposed to be impossible: no JIT, no fork/exec, no way out of the
sandbox. Most Japanese words for the impossible end in "…so it does not exist."
This one ends in "…and yet it happened," which is the only kind that fits a
thing that runs.

Hyotan is not a distribution (the rootfs is Alpine, and there is no kernel —
only iSH's syscall translation layer). The "Linux" is a nod to the naming
tradition of short, single-word distros.

## 旧名

2026-09-21 まで `agentcase` と呼んでいた。API の対応は次のとおり。

| 旧 | 新 |
|---|---|
| `agentcase.h` | `hyotan.h` |
| `AgentCaseRuntime` / `AgentCaseProcess` | `HyotanRuntime` / `HyotanProcess` |
| `libagentcase.a` | `libhyotan.a` |
| `-Dagentcase=true` | `-Dhyotan=true` |
| `AGENTCASE_BUILD_DIR` / `AGENTCASE_TOOLS_DIR` | `HYOTAN_BUILD_DIR` / `HYOTAN_TOOLS_DIR` |
| `agentcase/scripts/build-runtime.sh` | `hyotan/scripts/build-runtime.sh` |
