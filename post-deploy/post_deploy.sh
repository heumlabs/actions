#!/bin/bash
set -e
export TZ=Asia/Seoul

main() {
  >&2 echo "[Post Deploy] 시작"
  tickets=$(defect_tickets || true)
  if [ -z "$tickets" ]; then
    exit 0
  fi
  >&2 echo "--- 발견된 티켓 목록 ---"
  >&2 echo "$tickets"
  >&2 echo "----------------------"

  release_tag=$(generate_release_tag)
  github_release_url=$(make_github_release_url "$release_tag")

  transition_tickets "$tickets"
  delete_feature_branches "$tickets"
  jira_release_url=$(call_jira_release_api "$tickets" "$release_tag" "$github_release_url")
  call_github_release_api "$release_tag" "$jira_release_url"
  >&2 echo "[Post Deploy] 완료"
}

# ---- 함수 정의부 ----
defect_tickets() {
  MERGE_COMMIT=$(git rev-parse origin/main)
  PARENT_COUNT=$(git rev-list --parents -n 1 $MERGE_COMMIT | awk '{print NF}')
  if [ "$PARENT_COUNT" -lt 3 ]; then
    return 1
  fi
  FIRST_PARENT_SHA=$(git rev-list --parents -n 1 $MERGE_COMMIT | awk '{print $2}')
  # 영문 3자리-숫자 패턴의 JIRA 티켓 추출
  tickets=$(git log --pretty=%B ${FIRST_PARENT_SHA}..${MERGE_COMMIT} | grep -oE "[A-Z]{3}-[0-9]+" | sort | uniq)
  if [ -z "$tickets" ]; then
    return 1
  fi
  echo "$tickets"
}

get_transition_id() {
  local issue_key=$1
  # "배포"와 "완료" 두 단어가 모두 포함된 transition 찾기
  curl -s -X GET -u "$JIRA_USER:$JIRA_API_KEY" \
    -H "Content-Type: application/json" \
    "https://heumlabs.atlassian.net/rest/api/3/issue/$issue_key/transitions" | \
    jq -r '.transitions[] | select(.name | test("배포.*완료|완료.*배포")) | .id' | head -n 1
}

transition_ticket() {
  local ticket=$1
  local transition_id=$2
  curl -s -X POST -u "$JIRA_USER:$JIRA_API_KEY" \
    -H "Content-Type: application/json" \
    --data '{"transition":{"id":"'$transition_id'"}}' \
    "https://heumlabs.atlassian.net/rest/api/3/issue/$ticket/transitions"
}

transition_tickets() {
  local tickets="$1"
  >&2 echo "--- JIRA 티켓 상태 변경 ---"
  echo "$tickets" | while read ticket; do
    transition_id=$(get_transition_id $ticket)
    if [ -z "$transition_id" ]; then
      >&2 echo "$ticket: 변경 실패 (transition id 없음)"
      continue
    fi
    response=$(transition_ticket $ticket $transition_id)
    if [ -n "$(echo "$response" | jq -r '.errorMessages // empty')" ]; then
      >&2 echo "$ticket: 변경 실패"
    else
      >&2 echo "$ticket: 변경 성공"
    fi
  done
}

delete_feature_branches() {
  local tickets="$1"
  >&2 echo "--- Feature 브랜치 삭제 ---"
  echo "$tickets" | while read ticket; do
    [ -z "$ticket" ] && continue
    BRANCH="feature/$ticket"
    if git push origin --delete $BRANCH &>/dev/null; then
      >&2 echo "$BRANCH: 삭제 성공"
    else
      >&2 echo "$BRANCH: 삭제 실패"
    fi
  done
}

generate_release_tag() {
  local new_tag suffix orig_tag
  new_tag=$(date '+%Y%m%d-%H%M')
  suffix=1
  orig_tag=$new_tag
  while git tag | grep -q "^$new_tag$"; do
    new_tag="${orig_tag}.${suffix}"
    suffix=$((suffix+1))
  done
  >&2 echo "릴리즈 태그: $new_tag"
  echo "$new_tag"
}

make_github_release_url() {
  local tag="$1"
  echo "https://github.com/${GITHUB_REPOSITORY}/releases/tag/${tag}"
}

call_jira_release_api() {
  local tickets="$1"
  local release_tag="$2"
  local github_release_url="$3"

  >&2 echo "--- JIRA Release 생성 ---"

  # 첫 번째 티켓에서 프로젝트 키 추출
  local first_ticket=$(echo "$tickets" | head -n 1)
  local project_key=$(echo "$first_ticket" | cut -d'-' -f1)
  
  local release_name="${project_key} ${release_tag}"
  local jira_release_response=$(curl -s -X POST \
    -u "$JIRA_USER:$JIRA_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data '{
      "name": "'"$release_name"'",
      "released": true,
      "releaseDate": "'"$(date -u '+%Y-%m-%d')"'",
      "project": "'"$project_key"'"
    }' \
    "https://heumlabs.atlassian.net/rest/api/3/version")

  jira_release_id=$(echo "$jira_release_response" | jq -r '.id')
  local jira_release_url="https://heumlabs.atlassian.net/projects/${project_key}/versions/${jira_release_id}"

  # Related Work 등록
  curl -s -X POST "https://heumlabs.atlassian.net/rest/api/3/version/${jira_release_id}/relatedwork" \
    -u "$JIRA_USER:$JIRA_API_KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data '{
      "url": "'"$github_release_url"'",
      "title": "GitHub Release",
      "category": "documentation"
    }' > /dev/null

  for ticket in $tickets; do
    [ -z "$ticket" ] && continue
    >&2 echo "$ticket: Fix Version 추가"
    curl -s -X PUT \
      -u "$JIRA_USER:$JIRA_API_KEY" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data '{
        "update": {
          "fixVersions": [
            {
              "add": {
                "id": "'"${jira_release_id}"'"
              }
            }
          ]
        }
      }' \
      "https://heumlabs.atlassian.net/rest/api/3/issue/${ticket}"
  done

  echo "$jira_release_url"
}

call_github_release_api() {
  local release_tag="$1"
  local jira_release_url="$2"

  >&2 echo "--- GitHub Release 생성 ---"

  git tag "$release_tag"
  git push origin "$release_tag"

  local github_release_body="자동 배포 기록"
  if [ -n "$jira_release_url" ]; then
    github_release_body="자동 배포 기록: $jira_release_url"
  fi

  # 깔끔한 JSON 처리를 위해 변수 escape
  local github_release_body_escaped=$(echo "$github_release_body" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\n/\\n/g')

  local response=$(curl -s -X POST \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    --data '{
      "tag_name": "'"$release_tag"'",
      "target_commitish": "main",
      "name": "'"$release_tag"' 배포",
      "body": "'"$github_release_body_escaped"'",
      "draft": false,
      "prerelease": false
    }' \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases")

  local status=$(echo "$response" | jq -r '.message // "success"')
  if [ "$status" == "success" ]; then
    >&2 echo "GitHub Release 생성 성공"
  else
    >&2 echo "GitHub Release 생성 실패: $status"
  fi
}

main "$@"
