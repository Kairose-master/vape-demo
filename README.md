# VAPE — Verifiable AI Policy & Execution

**사용자 대화 · 감사자 파일 관리 네이티브 통합 콘솔 (`unified-console`)**

VAPE는 데이터 등급(L1/L2/L3)에 따른 AI 모델 라우팅, 네트워크 격리 파일 처리(App Sandbox / 익명 파이프), Ed25519 로컬 무결성 감사 서명, 그리고 사설 Hyperledger Besu 앵커링을 단일 macOS 네이티브 AppKit 콘솔로 통합한 검증 데모입니다.

> **참고:** 이 저장소에는 선별된 소스 코드만 포함되어 있습니다. 설치 스크립트, 바이너리, 개인 자료, API 키, 외부 도구(Besu/JDK/soljson) 및 기존 감사/체인 상태는 포함되지 않으며, 시작만으로 모델·체인·모의가 자동 실행되지 않습니다.

---

## 📋 사전 요구사항 및 외부 도구 설치

실행 모드에 따라 필요한 환경이 다릅니다. **기본 모의 데모**는 Python 3.9+만 있으면 되며, **실제 온디바이스 Apple 모델 + 사설 Besu 원장**을 연동하려면 아래 시스템 조건과 외부 도구를 먼저 설치해야 합니다.

### 1. 시스템 및 하드웨어 요구사항
* **기본 웹 모의 데모:** Python 3.9 이상 (별도 `pip` 패키지 불필요)
* **통합 네이티브 콘솔 (모의 모델):** macOS 13 이상, Apple Command Line Tools (`xcode-select --install`)
* **실제 Apple 모델 + 로컬 Besu 통합 실행:**
  * **하드웨어/OS:** Apple Silicon Mac (`arm64`), **macOS 26 이상**
  * **SDK 및 모델:** `FoundationModels` 포함 SDK, Apple Command Line Tools, 기기 내 Apple Intelligence 모델 활성화(`ready`)

### 2. 필수 도구 설치 명령어 (실제 Apple + Besu 연동 시)
저장소 상위 형제 폴더(`../tools`)에 외부 도구를 배치하는 기준의 설치 스크립트입니다.

```bash
# 1) Apple Command Line Tools 및 Node.js 설치 (Homebrew 기준)
xcode-select --install 2>/dev/null || true
brew install node

# 2) 작업 디렉터리 생성 (저장소 상위 ../tools 경로)
mkdir -p ../tools && cd ../tools

# 3) Hyperledger Besu 26.11.1 다운로드 및 압축 해제
curl -fL -o besu-26.11.1.tar.gz \
  "https://github.com/hyperledger/besu/releases/download/26.11.1/besu-26.11.1.tar.gz"
tar -xzf besu-26.11.1.tar.gz
# -> 생성 경로: ../tools/besu-26.11.1

# 4) Temurin JDK 25.0.5.1+2 (macOS aarch64) 다운로드 및 압축 해제
curl -fL -o OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5.1_2.tar.gz \
  "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5.1%2B2/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5.1_2.tar.gz"
tar -xzf OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5.1_2.tar.gz
# -> 생성 경로: ../tools/jdk-25.0.5.1+2/Contents/Home

# 5) Solidity Compiler 0.8.28 (soljson-0.8.28.js) 다운로드
curl -fL -o soljson-0.8.28.js \
  "https://binaries.soliditylang.org/bin/soljson-v0.8.28+commit.7893614a.js"

# 원래 디렉터리로 복귀
cd -
```

### 3. 도구 경로 설정 (기본 경로와 다를 경우)
도구는 기본적으로 저장소 상위 형제 폴더(`../tools`)를 자동 참조합니다. 다른 경로에 설치한 경우 저장소 루트에 `.runtime/launcher-settings.json` 파일을 생성해 경로를 지정하세요.

```bash
mkdir -p .runtime
cat << 'EOF' > .runtime/launcher-settings.json
{
  "toolsDirectory": "../tools",
  "nodeDirectory": "/opt/homebrew/bin"
}
EOF
```

---

## 🚀 Quick Start (실행 방법)

저장소를 클론한 뒤 환경에 맞는 실행 모드를 선택하세요.

```bash
git clone -b unified-console https://github.com/Kairose-master/vape-demo.git
cd vape-demo
python3 --version  # Python 3.9 이상 확인
```

### 1. 실제 Apple 모델 + 로컬 Besu 통합 실행 (도구 설치 완료 시)
```bash
# 1) 도구 SHA256 및 Apple 모델 준비 상태 사전 점검 (추론/노드 시작 없음)
python3 demo.py --mode preflight --tools-dir ../tools

# 2) 창 없는(Headless) 실제 Apple 1회 + Besu 채굴/RPC 재조회 검증
python3 demo.py --mode unified-check --tools-dir ../tools

# 3) 실제 Apple + Besu 발표용 통합 UI 실행
python3 demo.py --mode unified --tools-dir ../tools
```

### 2. 통합 네이티브 콘솔 실행 (macOS AppKit UI)
```bash
chmod +x "Start VAPE.command"
./"Start VAPE.command"
```
* Finder에서 `Start VAPE.command`를 **더블클릭**해도 동일하게 실행됩니다. (최초 실행 시 설치된 CLT로 컴파일하므로 시간이 다소 걸릴 수 있습니다.)
* **기본 진입 화면:** 사용자 대화 화면 (감사자 화면 전환 및 상세 도구는 상단/내부 UI에서 전환)

### 3. 기본 웹 모의 데모 실행 (외부 도구·Apple 모델 불필요)
Python 3.9+ 환경과 브라우저만 있으면 OS에 관계없이 정책·감사·격리 흐름을 테스트할 수 있습니다.

```bash
python3 demo.py
```
* 터미널에 출력된 `http://127.0.0.1:<임시포트>` 주소를 브라우저에서 직접 엽니다. (`Ctrl+C`로 종료)

### 4. 자체 검증 및 상태 점검 명령어
실행 전 현재 Mac의 준비 상태나 보안 경계 테스트를 먼저 확인할 수 있습니다.

```bash
# 1) 현재 Mac의 실제 Apple 모델 및 로컬 도구 준비 상태 확인 (미준비 시 exit 2)
./"Start VAPE.command" --check

# 2) 합성 경계·금지 입력·실패 상태 및 HTTP 진입점 자체 검증
./"Start VAPE.command" --self-test
# 또는: python3 demo.py --self-test

# 3) 비표시 레이아웃·Sandbox 연결·익명 파이프·빈 키 UI 검사 (추론/키 호출 0회)
./"Start VAPE.command" --ui-test

# 4) GUI QA 모드 (별도 합성 레지스트리가 적용된 테스트 창 실행)
./"Start VAPE.command" --gui-qa
```

---

## 📋 데모 시나리오 워크플로 (같은 파일 검증)

통합 콘솔(`Start VAPE.command`) 실행 후 아래 순서대로 권한 격리부터 체인 앵커링까지 검증할 수 있습니다.

1. **[감사자 화면] 파일 등록 및 권한 부여**
   * 합성 TXT 파일을 가져온 뒤 등급(`L1`, `L2`, `L3`)을 저장하고 **사용자 B 읽기 허용**을 설정합니다.
2. **[사용자 화면] 프롬프트 전송**
   * 하단 첨부 목록에서 감사자가 허용한 등록 ID·등급·revision을 선택합니다. (OS 파일 탐색기나 드래그앤드롭 첨부는 차단됨)
   * 모델 설정에서 **Apple 로컬**을 선택하고 질의(예: *"이 문서를 한 문장으로 요약해 주세요."*)를 입력 후 전송(`⌘ + Return`)합니다.
3. **[정책 및 결과 확인]**
   * **L1:** Cloud 호출을 원천 차단(`deny-no-send`)하고 로컬 Apple 모델만 실행합니다.
   * **L2:** 로컬 실행 외에, Cloud 선택 시 실제 전송될 `프롬프트+문서 전문` 확인창을 띄워 사용자의 명시적 1회 승인 후에만 OpenAI로 전송합니다. (`approval-required-no-send`)
   * **L3:** 외부 송신은 차단되며, 감사자 화면에서 승인된 **새 로컬 리비전(`0600` 권한)** 파생 저장만 지원합니다.
4. **[체인 앵커링] Besu 앵커 · 독립 검증 (1회)**
   * 실행 결과가 Ed25519로 서명되면 활성화되는 **`같은 실행 Besu 앵커 · 독립 검증 (1회)`** 버튼을 누릅니다.
   * 파일 원문·경로·프롬프트는 제외하고 `policyRoot` 및 `executionRoot` 해시만 사설 localhost Besu 노드에 기록하며, `localDecision=allow`, `localDelivery=received`, `independentRead=true`, `nodeStopped=true` 상태를 확인합니다.
5. **[감사자 화면] 이력 재검증**
   * `저장된 감사 이력 재검증` 메뉴에서 서명 무결성과 보존된 체인 관측 기록을 재확인합니다.

---

## 🔒 핵심 아키텍처 및 보안 경계

* **프로세스 및 권한 분리:** 파일 도우미(File Helper)만 사용자 선택 읽기 전용(Security-Scoped Bookmark) 권한을 가지며 **네트워크 권한이 없습니다**. 반대로 API 키가 있는 콘솔 프로세스는 파일 시스템 직접 접근 권한이 없으며, 본문은 두 네이티브 프로세스 간 **익명 파이프(Anonymous Pipe)**로만 전달됩니다.
* **메모리 전용 대화 및 엄격한 페이로드 제한:** 대화 본문은 앱 프로세스 메모리에만 유지되며 종료 시 소멸합니다. 과거 대화 이력은 후속 추론이나 Cloud에 자동 전송되지 않습니다. (입력 메시지 최대 `64KiB`, 첨부 질의 최대 `8KiB`, 결합 전송 본문 `64KiB` 이하)
* **OpenAI Cloud L2 보안 통제:** API 키는 macOS Keychain(iCloud 동기화 비활성)에 로컬 저장되며, 실제 Cloud 송신은 L2 등급 문서에 한해 사용자가 본문 전체를 확인하고 **세션당 명시적 1회 승인**을 눌러야만 전송됩니다.
* **자동 전환/재시도 금지:** 모델 거부(`appleGuardrail`), 자산 미준비, 타임아웃, 체인 실패 시 결과를 성공으로 위장하거나 Cloud/모의 응답으로 자동 fallback 및 재전송하지 않습니다.
* **데이터 등급 정책 (v1 기준):**

| 등급 | 로컬 모델 처리 | 외부 Cloud 전송 | 파일 쓰기 / 파생 저장 |
| :--- | :---: | :---: | :--- |
| **L1** | 허용 | **차단** (`deny-no-send`) | 불가 |
| **L2** | 허용 | **조건부 허용** (전문 확인 + 1회 명시적 승인 후 지정 모델만 전송) | 불가 |
| **L3** | 허용 | **차단** | 감사자 별도 승인 시 `0600` 권한 새 로컬 리비전 저장만 허용 |

---

## 🛠 기타 개별 실행 및 진단 CLI 옵션

| 명령어 | 설명 |
| :--- | :--- |
| `python3 demo.py --mode native` | 네이티브 정책 경로 UI 실행 (Apple 모델 비활성) |
| `python3 demo.py --mode apple` | 실제 온디바이스 Apple 모델 단독 검증 UI 실행 |
| `python3 demo.py --mode native-check` | 네이티브 빌드 및 CPU 아키텍처(`arm64`/`x86_64`) 검사 |
| `python3 demo.py --mode cloud-build` | L2 OpenAI 단독 검증용 앱(`VAPE OpenAI Ready v2.app`) 빌드 |
| `python3 demo.py --mode besu --tools-dir <경로>` | 사설 단일 validator QBFT Besu(Chain ID `2026112403`) 단독 실검증 |
| `python3 -B native/SelectedFlow/check_apple_diagnostics.py` | Apple 프레임워크 실패/거부 진단 코드 합성 테스트 (호출 0회) |
| `python3 -B native/SelectedFlow/check_handoff.py` | 파일 및 정책 경계 핸드오프 테스트 |

---

## ⚠️ 보안 및 검증 범위 안내
* macOS 네이티브 앱은 로컬 **ad-hoc 서명** 빌드이며 Apple Developer ID 공증 배포 앱이 아닙니다. 보안 설정을 임의로 해제하지 마십시오.
* 단일 validator 사설 Besu 노드 및 로컬 Ed25519 키 pinning은 동일 기기·동일 사용자 신뢰 경계 내에서의 감사 무결성 데모용이며, 다중 조직 합의나 원격 하드웨어 Attestation을 대체하지 않습니다.
* 상세 검증 내역과 출처는 저장소 내 `portable/VALIDATION.md`, `portable/PROVENANCE.md`를 참조하세요.
