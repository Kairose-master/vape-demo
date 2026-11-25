# 통합 소스 패키지 검증 결과

온라인 iMac의 **arm64 / macOS 27.2**에서 새 worktree와 새 임시 디렉터리만 사용했습니다. `299dbfd3` 통합 경로를 포함하며, 이전 기본 ZIP에 없던 연결 경로를 새 압축 해제본에서 검증했습니다.

## 이 릴리스에서 확인한 사항

- 키 없는 기본·통합 방어·preflight·경로 처리·HTTP 진입점 **46 tests PASS**.
- Git 없는 ZIP을 공백이 있는 새 경로에 풀고 이동한 뒤 위 자체 검증 PASS.
- 같은 추출본의 공개 실행 명령 `demo.py --mode unified-check --tools-dir …`로 실제 통합 경로 PASS.
- 사전 점검: arm64/macOS 27.2, Foundation Models **ready**, 추론 없이 확인. Besu/JDK/soljson archive의 source-pinned SHA256 일치, 필요한 추출 파일·Node 존재 확인.
- 새 합성 파일에서 L1 Cloud **deny/not-started**, 실제 Apple **allow/received**, 해당 실행의 로컬 모델 호출 **1회**, 비어 있지 않은 응답 확인.
- 새 독립 Besu **chain ID 2026112403**, block 3 채굴 및 별도 RPC 재조회 성공. 관측 시각 **2026-11-24 17:33:07 UTC**. 성공 후 해당 새 노드 종료 확인. 현재 온라인 원장이라고 주장하지 않음.
- 서명 변조, event 누락, 정책 변경, 다른 run ID 거부. 체인 driver의 중복·순서 누락·루트 불일치·비인가 기록 거부 확인. 본문/파일 경로/키는 전송 증거에서 제외됨.
- 통합 네이티브 발표 앱 전체 빌드와 상태 계산 검사 PASS. 앱 창을 열거나 화면/AX/클립보드를 관찰하지 않음.

## 실제 재현에서 수정한 문제

첫 깨끗한 실행은 Apple 호출에 성공했으나 공백이 있는 임시 경로가 `BESU_OPTS`의 JVM 속성에서 분리되어 새 Besu 프로세스 시작이 실패했습니다. 그 노드의 종료를 확인하고 실패 자료를 그대로 보존했습니다. driver가 각 JVM 인자를 shell-quote하도록 수정했으며, 실제 Besu launcher와 같은 shell word parsing을 공백·작은따옴표·literal dollar 표현을 포함해 검증했습니다. 이후 **별도 새 실행**으로 위 전체 성공을 확인했습니다. 이전 실패 실행을 성공으로 바꾸거나 같은 실행을 자동 재전송하지 않았습니다.

## 검증하지 않은 범위

headless 시험의 파일 picker/security scope는 합성 시험 대역입니다. GUI의 실제 파일 선택·App Sandbox 승인·버튼→화면 결과, Apple 시스템 서비스 전체 네트워크 추적은 검증하지 않았습니다. OpenAI 요청·키 입력은 없었습니다. 기존 8765/발표 서버/앱/런타임/보안 설정은 건드리지 않았습니다.

MacBook Air는 연결하거나 깨우지 않았습니다. 다른 물리 Mac, macOS 13/26, Intel에서의 실제 실행을 주장하지 않습니다. 이 릴리스의 실제 빌드는 arm64이며 Intel/universal2 재빌드 검사는 별도 `native-check` 명령으로 제공합니다. 이전 기본 패키지의 교차 빌드 기록을 이 통합 실경로의 물리 기기 증명으로 사용하지 않습니다. Developer ID 서명·공증·조직 배포 검증도 아닙니다.

## 소스 패키지 경계

추적된 UTF-8 일반 소스·합성 fixtures·문서만 선별합니다. archive 내 각 파일이 커밋 원본과 일치하는지, CRC와 deterministic 재생성 SHA256을 검증합니다. credentials, runtime binaries, raw audit, chain 상태/생성 config, 개인 경로, Git 메타데이터와 화면 이미지는 넣지 않습니다. 도구는 별도 준비된 검증본을 사용하며 다운로드·설치하지 않습니다. 패턴 스캔은 이 선별 검토를 보완할 뿐 일반적인 보안 인증은 아닙니다.

## GitHub 소스 전용 후보 검사

- 검토된 릴리스 `b12b6120926eb828f2daab5a90a37b3486810b53`의 allowlist 106개 파일에 저장소 제외 규칙 `.gitignore`를 추가했다. 문서와 manifest 외의 실행 코드는 원본과 동일하다.
- 원본 Git 히스토리를 내보내지 않고 107개 UTF-8 일반 파일만 새 로컬 저장소로 만들었다. 바이너리, 실행 상태, 개인 경로, 토큰 패턴, private-key 블록 검사를 통과했다.
- 공백이 있는 경로의 새 **로컬 clone**에서 사용자 진입점 `python3 -B demo.py --self-test` 통과: 단위·계약·방어 검사와 독립 loopback HTTP 진입점을 합해 **46 tests PASS**. 해당 검사 프로세스만 정상 종료했다.
- 이 게시 준비 작업에서는 실제 Apple/Besu/OpenAI를 다시 호출하거나 기존 발표 앱을 실행하지 않았다. 위 실제 통합 검증은 원본 릴리스의 선행 결과이며 다른 Mac 재현을 대체하지 않는다.
- GitHub 원격 업로드 및 원격 clone은 사용자 브라우저 인증/새 비공개 저장소 생성 대기 상태다. 로컬 clone 검증을 원격 게시 검증으로 부르지 않는다.

### 별도 L2 Cloud 소스 확인

릴리스에 `native/ReadyCloud/{App,Core,SecurePaste,Tests,PasteTests}.swift`와 `build.py`가 실제 포함되어 있다. 새 로컬 clone의 공개 진입점 `python3 -B demo.py --mode cloud-build`로 합성 키/주입 전송 56 assertions, 보안 붙여넣기 4 checks, 앱 빌드와 `codesign --verify --strict`가 통과했다. Swift의 Selector 표기 권고 경고만 있었으며 빌드 실패는 없었다.

실제 API 호출은 0회, 앱 창을 열지 않았으며 실제 키·클립보드·OS 단축키를 사용하지 않았다. 내장 합성 L2 전송 앱은 실제 선택 TXT의 L1 Apple+Besu 흐름과 별개다. L2 Cloud 사건의 Besu 앵커나 임의 파일 Cloud 업로드는 이 경로에 포함되어 있지 않다. 다른 Mac에서 실제 계정/모델 권한과 네트워크를 사용한 호출은 사용자의 직접 키 입력과 송출 승인 뒤에만 확인할 수 있다.
