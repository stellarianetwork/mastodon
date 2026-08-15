---
name: verify-in-isolated-docker
description: Mastodonの変更を、ホストへ依存パッケージ、DBデータ、ログ、ビルド成果物、一時ファイルを作らず、ホストの固定ポートも前提にせずDocker内で検証する。Dockerでローカル動作確認する依頼、ホスト環境を汚さないよう指定された検証、RSpecやJavaScriptテスト、RailsとViteを使うブラウザ確認で使用する。
---

# Docker隔離動作確認

変更中のworktreeをDockerボリュームへ複製し、依存関係の導入、DB作成、テスト、Webサーバーの実行をコンテナ内で完結させる。
確認後は、この手順で作成したDockerリソースとブラウザ成果物だけを削除する。

## 隔離条件

- `.devcontainer/Dockerfile`から検証専用イメージを作る。
- worktreeは読み取り専用で一時コンテナへbind mountし、検証専用のsource volumeへコピーする。
- アプリコンテナにはsource volumeをmountし、ホストのworktreeを直接mountしない。
- PostgreSQLとRedisのデータには検証専用volumeを使う。
- 公開するポートは`127.0.0.1`へbindし、ホスト側のポートはDockerに自動割り当てさせる。
- `3000`などの固定値はコンテナ側の待受ポートとしてのみ扱い、同じホスト側ポートが空いていることを前提にしない。
- 検証専用の名前を付け、開始前と終了後に対象を列挙する。
- 既存リソース、Docker全体のcache、他のCompose projectには触れない。

`docker-compose.yml`はDBとRedisをリポジトリ配下へbind mountするため、この用途では使わない。
`.devcontainer/compose.yaml`もworktreeを読み書き可能な状態でmountするため、`up`には使わない。

## 開始前の確認

repo rootで作業し、現在の差分と既存Dockerリソースを記録する。

```bash
git rev-parse --show-toplevel
git status --short
docker ps -a --filter name='^/codex-mastodon-verify-' --format '{{.Names}}\t{{.Status}}'
docker network ls --filter name='^codex-mastodon-verify$' --format '{{.Name}}'
docker volume ls --filter name='^codex-mastodon-verify-' --format '{{.Name}}'
docker image inspect codex-mastodon-verify-app >/dev/null 2>&1 || true
```

いずれかの専用名が既に存在する場合は、前回の失敗で残ったものかをinspectして確認する。
所有元を確認できなければ削除せず、すべてのコマンドで別の一意なprefixを使う。

ブラウザ確認でも、ホスト側の固定ポートが空いていることは前提にしない。
`127.0.0.1::<container-port>`形式でDockerに空きポートを選ばせるため、事前の`lsof`確認は不要である。

## 検証環境の作成

検証専用イメージ、network、volumeを作る。

```bash
docker build --tag codex-mastodon-verify-app --file .devcontainer/Dockerfile .
docker network create codex-mastodon-verify
docker volume create codex-mastodon-verify-source
docker volume create codex-mastodon-verify-db-data
docker volume create codex-mastodon-verify-redis-data
```

`git rev-parse --show-toplevel`で得た絶対パスを`<repo-path>`へ入れ、worktreeをsource volumeへコピーする。
コマンド内で未検証の環境変数やglobを使わない。

```bash
docker run --rm \
  --mount type=bind,source=<repo-path>,target=/source,readonly \
  --volume codex-mastodon-verify-source:/workspaces/mastodon \
  codex-mastodon-verify-app \
  bash -lc 'cp -a /source/. /workspaces/mastodon/'
```

PostgreSQLとRedisを起動する。

```bash
docker run --detach --rm \
  --name codex-mastodon-verify-db \
  --network codex-mastodon-verify \
  --env POSTGRES_USER=postgres \
  --env POSTGRES_DB=postgres \
  --env POSTGRES_PASSWORD=postgres \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --volume codex-mastodon-verify-db-data:/var/lib/postgresql/data \
  postgres:14-alpine

docker run --detach --rm \
  --name codex-mastodon-verify-redis \
  --network codex-mastodon-verify \
  --volume codex-mastodon-verify-redis-data:/data \
  redis:7-alpine
```

アプリコンテナを起動する。
ブラウザ確認を行わない場合は、`--publish`を省く。

```bash
docker run --detach --rm \
  --name codex-mastodon-verify-app \
  --network codex-mastodon-verify \
  --publish 127.0.0.1::3000 \
  --env RAILS_ENV=development \
  --env NODE_ENV=development \
  --env BIND=0.0.0.0 \
  --env BOOTSNAP_CACHE_DIR=/tmp \
  --env DB_HOST=codex-mastodon-verify-db \
  --env DB_USER=postgres \
  --env DB_PASS=postgres \
  --env DB_PORT=5432 \
  --env REDIS_HOST=codex-mastodon-verify-redis \
  --env REDIS_PORT=6379 \
  --env ES_ENABLED=false \
  --env LOCAL_DOMAIN=localhost \
  --volume codex-mastodon-verify-source:/workspaces/mastodon \
  --workdir /workspaces/mastodon \
  codex-mastodon-verify-app \
  sleep infinity
```

ブラウザ確認を行う場合は、Dockerが割り当てたホスト側ポートを取得する。
コマンドが出力した数値を`<web-host-port>`として以降のコマンドへ入れる。
割り当ては起動ごとに変わり得るため、以前の値を再利用しない。

```bash
docker inspect codex-mastodon-verify-app \
  --format '{{(index (index .NetworkSettings.Ports "3000/tcp") 0).HostPort}}'
```

ブラウザ確認を行わず`--publish`を省いた場合は、この取得も不要である。
Streamingや別の補助サーバーを追加で公開する場合も固定ポートへbindせず、同じ形式で自動割り当てと取得を行う。

依存関係をコンテナ内へ導入し、DBを準備する。

```bash
docker exec codex-mastodon-verify-app bash -lc 'bundle install --jobs 4'
docker exec codex-mastodon-verify-app bash -lc 'corepack enable && yarn install --immutable'
docker exec codex-mastodon-verify-db pg_isready --username postgres
docker exec codex-mastodon-verify-app bash -lc 'bin/rails db:prepare'
```

`pg_isready`が失敗した場合は短い間隔で再確認し、PostgreSQLの起動完了後に`db:prepare`を実行する。

## テストの実行

変更範囲に対応するRSpecとJavaScriptテストをコンテナ内で実行する。
プロジェクトにpackage.jsonのscriptがある処理は、そのscript経由で実行する。

```bash
docker exec codex-mastodon-verify-app bash -lc 'bundle exec rspec <spec-paths>'
docker exec codex-mastodon-verify-app bash -lc 'yarn test:js run <test-paths>'
```

必要に応じてRubocop、ESLint、型検査も同じコンテナで実行する。
失敗した検証を通すために既存機能やテストを無効化しない。

## ブラウザ確認

ブラウザ確認では`playwright-cli`skillと`browser-verification`skillを併用する。
セッション名はrepo名の`mastodon`に固定し、`--headed`を付けない。

ブラウザ確認用のフロントエンドをワンショットでビルドしてから、Railsを起動する。
Vite開発サーバーとHMRはブラウザ確認に不要なため起動せず、ホストへ`3036`を公開しない。
ビルド成果物は検証専用のsource volume内だけに作られる。

```bash
docker exec codex-mastodon-verify-app bash -lc 'yarn build:development --mode development'
docker exec --detach \
  --env LOCAL_DOMAIN=localhost:<web-host-port> \
  codex-mastodon-verify-app \
  bash -lc 'bundle exec puma -C config/puma.rb > /tmp/puma.out 2>&1'
```

Dockerが割り当てたホスト側ポートでRailsへ到達できることを確認する。

```bash
curl --max-time 5 --fail http://localhost:<web-host-port>/health
```

検証対象のデータは、専用DBへ`bin/tootctl`または`bin/rails runner`で作る。
外部サービスへ投稿せず、公開ページまたはローカルAPIだけで検証できる状態を作る。

ラベル付きリンクを確認する場合は、次のように一時アカウントと投稿を作る。

```bash
docker exec \
  --env LOCAL_DOMAIN=localhost:<web-host-port> \
  codex-mastodon-verify-app bash -lc \
  'bin/tootctl accounts create browsercheck --email browsercheck@example.test --confirmed --approve'

docker exec \
  --env LOCAL_DOMAIN=localhost:<web-host-port> \
  --env STATUS_TEXT='表示確認 [label](http://example.com)' \
  codex-mastodon-verify-app \
  bin/rails runner \
  'account = Account.find_local("browsercheck"); status = PostStatusService.new.call(account, text: ENV.fetch("STATUS_TEXT"), visibility: :public); puts status.id'
```

最後に出力されたstatus IDを使い、`http://localhost:<web-host-port>/@browsercheck/<status-id>`を開く。

Playwrightのsnapshotとscreenshotは、`mktemp -d`で作った専用ディレクトリへ保存する。
最初のコマンドが返した絶対パスを`<playwright-output-path>`へ入れ、各Playwrightコマンドへ同じ`PLAYWRIGHT_MCP_OUTPUT_DIR`を渡す。

```bash
mktemp -d /tmp/mastodon-verify-playwright.XXXXXX
PLAYWRIGHT_MCP_OUTPUT_DIR=<playwright-output-path> playwright-cli -s=mastodon open http://localhost:<web-host-port>/@browsercheck/<status-id>
PLAYWRIGHT_MCP_OUTPUT_DIR=<playwright-output-path> playwright-cli -s=mastodon snapshot
PLAYWRIGHT_MCP_OUTPUT_DIR=<playwright-output-path> playwright-cli -s=mastodon --raw eval \
  "JSON.stringify([...document.querySelectorAll('a[href=\"http://example.com/\"]')].map(a => ({ text: a.textContent, href: a.getAttribute('href'), target: a.getAttribute('target'), rel: a.getAttribute('rel') })))"
PLAYWRIGHT_MCP_OUTPUT_DIR=<playwright-output-path> playwright-cli -s=mastodon --raw eval \
  "JSON.stringify({ title: document.title, bodyIncludesMarkup: document.body.innerText.includes('[label](http://example.com)'), bodyIncludesLabel: document.body.innerText.includes('表示確認 label') })"
PLAYWRIGHT_MCP_OUTPUT_DIR=<playwright-output-path> playwright-cli -s=mastodon screenshot
```

ラベル付きリンクでは、次の状態を確認する。

- 本文が`表示確認 label`と表示される。
- `[label](http://example.com)`という記法が本文へ露出しない。
- `label`の`href`が`http://example.com/`になる。
- リンクの`target`が`_blank`になり、`rel`が`noopener`を含む。
- ページタイトルがURLではなく`表示確認 label`を含む。
- screenshotでoverflowやレイアウト崩れがない。

ページが空になる場合はPumaのログとブラウザのnetwork failureを確認する。
起動直後だけ失敗した場合はPumaの起動完了を確認してからreloadし、snapshotを取り直す。

```bash
docker exec codex-mastodon-verify-app tail -n 120 /tmp/puma.out
PLAYWRIGHT_MCP_OUTPUT_DIR=<playwright-output-path> playwright-cli -s=mastodon reload
PLAYWRIGHT_MCP_OUTPUT_DIR=<playwright-output-path> playwright-cli -s=mastodon snapshot
```

development環境では未翻訳キーのconsole errorが出る場合があるため、件数だけで失敗と判定しない。
対象UI、network failure、例外stackを分けて確認する。

## 後片付け

成功と失敗のどちらでも後片付けを行う。
まず、自分で開いた非persistentブラウザを閉じる。

```bash
playwright-cli -s=mastodon close
playwright-cli list
```

今回作成したコンテナだけを停止する。
各コンテナは`--rm`付きなので、停止後に削除される。

```bash
docker stop --timeout 10 codex-mastodon-verify-app
docker stop --timeout 10 codex-mastodon-verify-db
docker stop --timeout 10 codex-mastodon-verify-redis
```

コンテナが消えたことを確認してから、専用network、volume、imageを削除する。

```bash
docker ps -a --filter name='^/codex-mastodon-verify-' --format '{{.Names}}\t{{.Status}}'
docker network rm codex-mastodon-verify
docker volume rm \
  codex-mastodon-verify-source \
  codex-mastodon-verify-db-data \
  codex-mastodon-verify-redis-data
docker image rm codex-mastodon-verify-app
```

`mktemp -d`で作ったPlaywright出力先は、実際の絶対パスと`/tmp/mastodon-verify-playwright.`prefixを確認してから、そのディレクトリだけを削除する。
削除前に内容を列挙し、`mktemp`が返した絶対パスを`<playwright-output-path>`へ入れる。

```bash
find <playwright-output-path> -maxdepth 2 -type f -print
rm -r -- <playwright-output-path>
```

リポジトリ内に`.playwright-cli`が作られた場合も、今回生成したファイルだけを列挙して削除し、既存成果物を巻き込まない。

最後にDockerリソース、ブラウザ、worktreeを確認する。

```bash
playwright-cli list
docker ps -a --format '{{.Names}}' | rg '^codex-mastodon-verify-' || true
docker network ls --format '{{.Name}}' | rg '^codex-mastodon-verify$' || true
docker volume ls --format '{{.Name}}' | rg '^codex-mastodon-verify-' || true
docker image inspect codex-mastodon-verify-app >/dev/null 2>&1 || true
git status --short
git diff --check
```

開始前と終了後の`git status --short`を比較し、検証対象の実装差分以外が増えていないことを確認する。
`docker system prune`、`docker volume prune`、未確認のrecursive削除は実行しない。
