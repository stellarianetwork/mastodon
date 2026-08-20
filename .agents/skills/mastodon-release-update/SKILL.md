---
name: mastodon-release-update
description: Stellaria NetworkのMastodon forkを新しいupstream releaseへ更新し、既存カスタマイズを移植して、verX.Y.Z branchとvX.Y.Z tagをpushし、GitHub ActionsによるDocker Hubのmulti-architecture image公開まで検証する。公式release notesを読み、image build後にserverで行うupgrade手順も案内する。stellarianetwork/mastodonで「Mastodonを更新」「いつものカスタマイズを取り込む」「release tagをpush」「Docker imageを作成」と依頼されたときに使う。
---

# Stellaria Mastodonのrelease更新

## 作業原則

- `origin`が`stellarianetwork/mastodon`、`upstream`が`mastodon/mastodon`を指すことを確認する。
- 現在のworktreeで作業し、別worktreeへ移らない。
- worktreeに未commit変更がある場合は、対象との重複を調べてから進める。
- version branchには、このrepositoryの既存規則である`verX.Y.Z`を使う。
- 一般的なbranch prefix規則を理由に`chore/verX.Y.Z`へ変更しない。
- 移植するcommit hashをskillへ固定せず、直前のversion branchとupstream tagから毎回導出する。
- 直前のカスタマイズ済みtagだけを移植元にしない。
  tag作成後に追加された修正を含めるため、直前のversion branchのtipまで調べる。
- upstream tagと同名のlocal tagはカスタマイズ済みcommitへ付け替えるため、upstream tagを別のref namespaceへ取得する。
- originに対象tagが存在する場合は、明示的な許可なしに上書きしない。
- branch、tagのpushが依頼に含まれない場合は、検証完了後にpush前で止める。
- default branchは、明示的に依頼された場合だけ変更する。

## 対象versionと移植元

依頼から`X.Y.Z`を特定し、stable releaseの形式に一致することを確認してから次の値を使う。

```bash
target_version='X.Y.Z'
[[ "$target_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
target_tag="v$target_version"
target_branch="ver$target_version"
```

versionが明示されていない場合は、upstreamのstable tagを確認する。
prereleaseをstable releaseとして選ばない。

originの`ver*`branchをversion順に並べ、対象versionの直前に運用していたbranchを`previous_branch`として選ぶ。
同じversionに派生branchがある場合は、default branchと履歴を確認して正規のversion branchを選ぶ。

```bash
git for-each-ref --format='%(refname:short)' \
  'refs/remotes/origin/ver*' | sed 's#^origin/##' | sort -V
previous_branch='verA.B.C'
previous_tag="v${previous_branch#ver}"
```

## repositoryとrefの確認

最初に状態、remote、default branchを確認する。

```bash
git status --short --branch
git remote -v
git remote get-url origin
git remote get-url upstream
git branch --show-current
gh repo view --json nameWithOwner,defaultBranchRef
```

originとupstreamのbranchを更新する。
カスタマイズ済みlocal tagとの衝突を避けるため、`git fetch --tags upstream`は使わない。

```bash
git fetch --prune origin
git fetch --prune upstream '+refs/heads/*:refs/remotes/upstream/*'
```

対象tagがupstreamに存在することを確認し、専用のremote-tracking refへ取得する。

```bash
git ls-remote --tags --refs upstream "refs/tags/$target_tag"
git fetch upstream "refs/tags/$target_tag:refs/remotes/upstream/releases/$target_tag"
git rev-parse "refs/remotes/upstream/releases/$target_tag^{commit}"
```

同じ方法で直前versionのupstream tagを`refs/remotes/upstream/releases/$previous_tag`へ取得する。
localの`vX.Y.Z`はカスタマイズ済みcommitを指すため、upstreamの基点として使わない。

対象branchとorigin tagが未作成か確認する。

```bash
git branch --list "$target_branch"
git ls-remote --heads origin "refs/heads/$target_branch"
git ls-remote --tags origin "refs/tags/$target_tag"
```

既存refが見つかった場合は、新規更新かやり直しかを履歴から判定する。
共有済みbranchやtagを推測で移動しない。

## カスタマイズcommitの抽出

直前のupstream tagから直前のversion branchまでを調べる。

```bash
git log --graph --oneline --decorate \
  "refs/remotes/upstream/releases/$previous_tag".."origin/$previous_branch"
git log --reverse --no-merges --format='%H %s' \
  "refs/remotes/upstream/releases/$previous_tag".."origin/$previous_branch"
git diff --stat \
  "refs/remotes/upstream/releases/$previous_tag".."origin/$previous_branch"
```

`--no-merges`の結果をそのまま機械的に採用せず、各commitのdiffを読む。
fork固有のPRがmergeされている場合は、merge commitではなく内容を持つ非merge commitを候補にする。
upstreamから別途backportされたcommitが混ざる場合は、対象releaseに同じ変更が含まれていないか確認する。

現在のforkでは、少なくとも次の不変条件を確認する。

- Accountのdisplay name上限が100である。
- Sidekiqの既定concurrencyが15である。
- Composeが`eaaaaaaaaaaai/stellaria-mastodon`と`eaaaaaaaaaaai/stellaria-mastodon-streaming`を参照する。
- Composeの各Mastodon serviceが対象versionを参照する。
- Web、streaming、Sidekiq serviceの`nofile`上限が65536である。
- release、nightly、security、PR用workflowがStellariaのDocker Hub repositoryを参照する。
- forkで不要なregistry loginやupstream専用設定が再導入されていない。

この一覧は移植候補の発見を補助するものであり、直前branchの全固有差分を省略する根拠にはしない。

## version branchへの移植

対象upstream tagのcommitからversion branchを作る。

```bash
git switch -c "$target_branch" \
  "refs/remotes/upstream/releases/$target_tag^{commit}"
```

抽出したカスタマイズcommitを古い順にcherry-pickする。
競合が起きたら、upstreamの新version変更とfork固有の意図を両方残す。

`docker-compose.yml`のimage行が競合した場合は、repository名をStellariaのものにし、tagを対象versionにする。
upstreamが追加したservice設定や依存versionを旧版へ戻さない。

cherry-pick後のcommitは小さい粒度を維持する。
新しく作るcommit messageはrepositoryのprefix規則と日本語表記に従う。
必要な`Co-authored-by` trailerを`--trailer`で付ける。

## 差分と設定の検証

移植結果と空白エラーを確認する。

```bash
git status --short --branch
git log --oneline --reverse \
  "refs/remotes/upstream/releases/$target_tag"..HEAD
git diff --stat \
  "refs/remotes/upstream/releases/$target_tag"..HEAD
git diff --check \
  "refs/remotes/upstream/releases/$target_tag"..HEAD
```

直前releaseのカスタマイズ列と今回の列を比較する。

```bash
git range-diff \
  "refs/remotes/upstream/releases/$previous_tag".."origin/$previous_branch" \
  "refs/remotes/upstream/releases/$target_tag"..HEAD
```

version変更やupstream変更による差だけが残ることを確認する。
`range-diff`で比較しづらいmerge履歴は、対象ファイルのdiffも個別に読む。

利用可能な範囲で設定を検証する。

```bash
docker compose config --no-interpolate --quiet
actionlint -shellcheck=
ruby -rerb -ryaml -e \
  "config = YAML.safe_load(ERB.new(File.read('config/sidekiq.yml')).result, permitted_classes: [Symbol], aliases: true); abort 'unexpected concurrency' unless config[:concurrency] == 15"
```

完全な`actionlint`が既存のShellCheck警告だけで失敗する場合は、構文検証の成功と既存警告を分けて報告する。
警告を消す目的で依頼範囲外のworkflowを変更しない。

RubyやNode.jsのコードを移植した場合は、repository指定runtimeで対象testを実行する。
runtimeや依存関係がなく実行できないtestは、理由と未確認範囲を明示する。
testを通すために機能を削除しない。

## branchとtagのpush

push前にdefault branchからのcommit列とworktreeを確認する。

```bash
default_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git log --oneline "origin/$default_branch"..HEAD
git status --porcelain=v1
```

不要な中間commitやdebug commitがないことを確認する。
pushが依頼済みなら、version branchをtagより先にpushする。

```bash
git push --set-upstream origin "$target_branch"
```

originに対象tagがないことを再確認する。
localの対象tagがupstream commitを指していても、確認済みのカスタマイズ済みcommitへだけ付け替える。

```bash
git ls-remote --tags origin "refs/tags/$target_tag"
git tag --force "$target_tag" HEAD
git show -s --format='%H%n%D%n%s' "$target_tag"
git push origin "refs/tags/$target_tag"
```

originに同名tagが存在する場合は、force pushせず停止する。
誤ったremote branchの削除は、正しいbranchとtagが同じcommitを指すことを確認し、削除の許可がある場合だけ行う。

## GitHub Actionsの監視

tag pushで`build-releases.yml`が起動したrunを、tag名とcommit SHAで特定する。

```bash
gh run list --workflow build-releases.yml --limit 10 \
  --json databaseId,headBranch,headSha,status,conclusion,url
```

runの全jobが完了するまで監視する。

```bash
gh run view "$run_id" --json status,conclusion,url,jobs \
  --jq '{status, conclusion, url, jobs: [.jobs[] | {name, status, conclusion}]}'
```

失敗した場合は、失敗jobとlogを読んで原因を特定する。
原因を確認せずにrerunしない。

```bash
gh run view "$run_id" --log-failed
```

deprecation warningとbuild失敗を区別する。
warningが将来の対応を必要とする場合は、release結果と分けて報告する。

## Docker Hubの公開確認

Actions成功後に、通常版とstreaming版のmanifestを確認する。

```bash
docker buildx imagetools inspect \
  "eaaaaaaaaaaai/stellaria-mastodon:$target_tag"
docker buildx imagetools inspect \
  "eaaaaaaaaaaai/stellaria-mastodon-streaming:$target_tag"
```

各imageがOCI indexとして公開され、`linux/amd64`と`linux/arm64`を含むことを確認する。
通常版とstreaming版のdigestを記録する。

## release notesとserver作業案内

対象releaseの公式release notesを`gh`で取得する。

```bash
gh release view "$target_tag" --repo mastodon/mastodon \
  --json body,publishedAt,tagName,url
```

`Upgrade notes`、`Update steps`、`When using Docker`を優先して読み、dependencies、長時間migration、停止時間、互換性変更、追加設定も確認する。
移植元versionからのdirect upgradeが説明対象に含まれない場合は、飛ばしたstable releaseのrelease notesも順に読む。

Actions成功とmanifest公開を確認した後、image build後にserverで行う作業をcopy-paste可能な順序で報告する。
ユーザーがActionsの完了待機を不要とした場合も案内は出し、image公開が未確認であることを明記する。

- DB backupとbackup fileの確認
- server側Compose設定を対象tagへ更新し、通常版とstreaming版をpull
- release notesで指定されたpre-deployment migration
- Web、streaming、Sidekiqを含むMastodon processの再起動
- release notesで指定されたpost-deployment migration
- Webとstreamingのhealth check、container状態、直近logの確認
- release固有の注意事項と、長時間処理を中断しないための運用上の注意

一般的なMastodon更新手順をrelease notesの代わりに使わない。
release notesが要求していないcache clear、検索index再構築、host上のasset build、依存関係更新を推測で追加しない。
Docker imageに含まれる処理とserverで別途必要な処理を区別する。
repositoryのrelease作業にserver操作は含めず、ユーザーが明示的に依頼した場合だけserverでコマンドを実行する。

最後にlocal branch、origin branch、origin tagが同じcommitを指すことを確認する。

```bash
git rev-parse HEAD
git ls-remote --heads origin "refs/heads/$target_branch"
git ls-remote --tags origin "refs/tags/$target_tag"
git status --short --branch
```

## 完了報告

次の結果を簡潔に報告する。

- 移植したカスタマイズ
- version branch、tag、commit SHA
- 実行した検証と未実行test
- Actions runの結果とURL
- 公開した2種類のimage、digest、対応architecture
- 公式release notesのURLと、image build後にserverで行う作業
- worktreeの状態

default branchを変更していない場合は、変更したように報告しない。
