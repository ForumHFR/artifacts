#!/usr/bin/env bash
#
# bench-rf2.sh — kit de benchmark communautaire pour les builds Gradle de Redface 2
# (ForumHFR/redface2, https://github.com/ForumHFR/redface2).
#
# Objectif : mesurer, sur VOTRE machine, le temps des étapes réelles du build/CI du
# projet (configuration, compilation, tests, lint, detekt) afin de constituer une table
# comparative CPU/RAM et d'identifier les zones lentes et le potentiel d'accélération
# (parallélisme local, build cache, workload déporté).
#
# Ce script est LECTURE SEULE vis-à-vis du projet : il clone une copie dédiée sous
# $BENCH_RF2_DIR, jamais votre propre checkout (le répertoire cible est refusé s'il
# existe déjà sans le marqueur posé par ce script — voir setup_repo). Aucune
# télémétrie, aucun envoi automatique de résultat : le bloc de résultats produit en
# sortie est à copier-coller manuellement par vous (par ex. sur le topic HFR du
# projet). Accès réseau utilisés : clone/fetch du dépôt GitHub et téléchargement des
# dépendances Gradle (distribution, plugins, artefacts) — rien d'autre.
#
# Usage :
#   ./bench-rf2.sh [--full] [--ref <sha-ou-tag>] [--dir <chemin>] [--keep] [-h|--help]
#
#   --full        Ajoute les scénarios S5a (detekt) et S5b (lint), comme la CI. Sans
#                 ce flag, seuls S1-S4 tournent (plus rapide).
#   --ref REF     Commit/tag à bencher (défaut : 164b6da5, la release 0.33.0). Fixer
#                 le ref garantit que tous les participants benchent EXACTEMENT le
#                 même code.
#   --dir PATH    Répertoire de travail dédié (défaut : $BENCH_RF2_DIR ou
#                 ~/.cache/bench-rf2). Sécurité : si "<dir>/redface2" existe déjà sans
#                 le marqueur ".bench-rf2-clone" posé par ce script à son premier
#                 clone, le script REFUSE de continuer (il y exécute sinon un
#                 checkout --force / reset --hard / clean -fdx).
#   --keep        Ne supprime pas le contenu de $GRADLE_USER_HOME dédié après usage
#                 (comportement par défaut : on garde toujours — ce flag existe pour
#                 rendre explicite qu'aucun nettoyage agressif n'a lieu).
#   -h, --help    Affiche cette aide.
#
# Variables d'environnement reconnues :
#   BENCH_RF2_DIR   même rôle que --dir (même sécurité du marqueur de clone).
#   BENCH_RF2_REPO_URL  URL du dépôt à cloner (défaut : https://github.com/ForumHFR/redface2.git).
#   ANDROID_HOME / ANDROID_SDK_ROOT  SDK Android déjà installé (requis, non fourni par ce script).
#
# Portabilité : bash 4+, testé visé Linux et macOS. Nécessite : git, java (JDK 17+),
# un SDK Android déjà installé, ~10 Go d'espace disque libre au premier run (SDK
# packages + dépendances Gradle + artefacts de build).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Constantes et valeurs par défaut
# ---------------------------------------------------------------------------

readonly SCRIPT_VERSION="1.1.0"
readonly DEFAULT_REPO_URL="https://github.com/ForumHFR/redface2.git"
# 164b6da5 = commit "chore(release): 0.33.0" (tag app-v* / release 0.33.0). Fixer ce
# ref garantit un code IDENTIQUE pour tous les participants du bench.
readonly DEFAULT_REF="164b6da5"
readonly DEFAULT_REF_LABEL="0.33.0"
readonly MIN_JDK_MAJOR=17
readonly MIN_DISK_GB=10
# android-compileSdk dans gradle/libs.versions.toml du dépôt bencé.
readonly ANDROID_PLATFORM_HINT="36"

BENCH_DIR="${BENCH_RF2_DIR:-$HOME/.cache/bench-rf2}"
REPO_URL="${BENCH_RF2_REPO_URL:-$DEFAULT_REPO_URL}"
REF="$DEFAULT_REF"
REF_LABEL="$DEFAULT_REF_LABEL"
FULL_RUN=0

# ---------------------------------------------------------------------------
# 1. Parsing des arguments
# ---------------------------------------------------------------------------

print_help() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full)
            FULL_RUN=1
            shift
            ;;
        --ref)
            REF="${2:?--ref nécessite une valeur}"
            REF_LABEL="$REF"
            shift 2
            ;;
        --dir)
            BENCH_DIR="${2:?--dir nécessite une valeur}"
            shift 2
            ;;
        --keep)
            # Pas de nettoyage agressif par défaut de toute façon ; drapeau conservé
            # pour rendre le comportement explicite dans les logs/rapports.
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Argument inconnu : $1" >&2
            print_help >&2
            exit 1
            ;;
    esac
done

REPO_DIR="$BENCH_DIR/redface2"
GRADLE_USER_HOME_DEDICATED="$BENCH_DIR/gradle-home"
RESULTS_DIR="$BENCH_DIR/results"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG_DIR="$RESULTS_DIR/$RUN_TS"

mkdir -p "$BENCH_DIR" "$GRADLE_USER_HOME_DEDICATED" "$RESULTS_DIR" "$RUN_LOG_DIR"

# Exporté tôt (avant le premier appel à ./gradlew dans collect_machine_info) pour que
# TOUT appel gradlew, y compris la simple lecture de version, reste confiné au
# répertoire dédié — jamais le ~/.gradle réel de l'utilisateur.
export GRADLE_USER_HOME="$GRADLE_USER_HOME_DEDICATED"

log()  { printf '[bench-rf2] %s\n' "$*"; }
warn() { printf '[bench-rf2] ATTENTION: %s\n' "$*" >&2; }
die()  { printf '[bench-rf2] ERREUR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Vérification des prérequis
# ---------------------------------------------------------------------------

check_prereqs() {
    log "Vérification des prérequis..."

    command -v git >/dev/null 2>&1 || die "git est introuvable. Installez git avant de relancer."

    command -v java >/dev/null 2>&1 || die "java est introuvable. Installez un JDK 17+ (ex. Temurin 17/21) avant de relancer."

    local java_version_raw java_major
    java_version_raw="$(java -version 2>&1 | head -n1)"
    # Formats possibles: 'openjdk version "17.0.9" ...' ou 'java version "1.8.0_..."'.
    java_major="$(printf '%s' "$java_version_raw" | grep -oE '"[0-9]+(\.[0-9]+)?' | head -n1 | tr -d '"' | cut -d. -f1)"
    if [[ "$java_major" == "1" ]]; then
        # Vieux schéma de version "1.8" -> Java 8.
        java_major="$(printf '%s' "$java_version_raw" | grep -oE '"1\.[0-9]+' | cut -d. -f2)"
    fi
    if [[ -z "$java_major" ]] || ! [[ "$java_major" =~ ^[0-9]+$ ]]; then
        warn "Impossible de déterminer la version de java depuis: $java_version_raw (on continue, mais le build attend un JDK 17+)."
    elif (( java_major < MIN_JDK_MAJOR )); then
        die "JDK $MIN_JDK_MAJOR+ requis (build-logic du projet compile en sourceCompatibility=17), trouvé: $java_version_raw"
    fi
    log "  java: $java_version_raw"

    local sdk_dir=""
    if [[ -n "${ANDROID_HOME:-}" && -d "${ANDROID_HOME:-}" ]]; then
        sdk_dir="$ANDROID_HOME"
    elif [[ -n "${ANDROID_SDK_ROOT:-}" && -d "${ANDROID_SDK_ROOT:-}" ]]; then
        sdk_dir="$ANDROID_SDK_ROOT"
        export ANDROID_HOME="$ANDROID_SDK_ROOT"
    else
        for candidate in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk" "$HOME/android-sdk"; do
            if [[ -d "$candidate" ]]; then
                sdk_dir="$candidate"
                export ANDROID_HOME="$candidate"
                export ANDROID_SDK_ROOT="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$sdk_dir" ]]; then
        die "Aucun SDK Android trouvé (ANDROID_HOME / ANDROID_SDK_ROOT non défini, et aucun des emplacements par défaut n'existe). Installez le SDK Android (cmdline-tools + platform ${ANDROID_PLATFORM_HINT} + build-tools) et exportez ANDROID_HOME avant de relancer. Ce script ne l'installe pas."
    fi
    log "  SDK Android: $sdk_dir"
    export ANDROID_HOME="$sdk_dir"
    export ANDROID_SDK_ROOT="$sdk_dir"

    # Un ANDROID_HOME/ANDROID_SDK_ROOT vide ou incomplet (dossier présent mais sans
    # rien dedans) ne doit PAS passer pour un SDK utilisable : on vérifie la présence
    # réelle de la plateforme requise et d'au moins une version de build-tools avant
    # d'annoncer "Prérequis OK".
    local platform_jar="$sdk_dir/platforms/android-${ANDROID_PLATFORM_HINT}/android.jar"
    if [[ ! -f "$platform_jar" ]]; then
        die "SDK Android trouvé sous '$sdk_dir' mais incomplet : '$platform_jar' est absent. Installez la plateforme (sdkmanager \"platforms;android-${ANDROID_PLATFORM_HINT}\") avant de relancer."
    fi
    log "  plateforme android-${ANDROID_PLATFORM_HINT}: présente"

    local build_tools_dir="$sdk_dir/build-tools"
    local build_tools_versions=""
    if [[ -d "$build_tools_dir" ]]; then
        build_tools_versions="$(ls -1 "$build_tools_dir" 2>/dev/null | tr '\n' ' ')"
    fi
    if [[ -z "${build_tools_versions// /}" ]]; then
        die "SDK Android trouvé sous '$sdk_dir' mais aucun build-tools installé sous '$build_tools_dir'. Installez au moins une version (sdkmanager \"build-tools;<version>\") avant de relancer."
    fi
    log "  build-tools installés: $build_tools_versions"

    local avail_kb avail_gb
    avail_kb="$(df -Pk "$BENCH_DIR" 2>/dev/null | tail -n1 | awk '{print $4}' || true)"
    if [[ -n "$avail_kb" && "$avail_kb" =~ ^[0-9]+$ ]]; then
        avail_gb=$(( avail_kb / 1024 / 1024 ))
        if (( avail_gb < MIN_DISK_GB )); then
            warn "Espace disque libre sous $BENCH_DIR: ~${avail_gb} Go (recommandé: ${MIN_DISK_GB}+ Go pour le premier run — SDK packages, cache Gradle, artefacts de build). Le bench peut échouer par manque de place."
        else
            log "  disque libre: ~${avail_gb} Go sous $BENCH_DIR"
        fi
    else
        warn "Impossible de vérifier l'espace disque disponible sous $BENCH_DIR."
    fi

    log "Prérequis OK."
}

# ---------------------------------------------------------------------------
# 3. Clone / réutilisation du dépôt sur un ref fixe
# ---------------------------------------------------------------------------

setup_repo() {
    log "Préparation du dépôt de bench sous $REPO_DIR (ref cible: $REF)..."
    # Marqueur posé juste après le clone initial : seul un répertoire portant ce
    # fichier est considéré comme "notre" clone dédié. Sans ce garde-fou, un --dir
    # pointant par erreur (ou par malveillance) vers un répertoire qui contient DÉJÀ
    # un checkout "redface2" — par ex. le checkout de travail réel du mainteneur —
    # subirait plus bas un checkout --force / reset --hard / clean -fdx destructeur.
    local marker="$REPO_DIR/.bench-rf2-clone"

    if [[ -e "$REPO_DIR" ]]; then
        if [[ -f "$marker" ]]; then
            log "  clone existant réutilisé (marqueur $marker présent) — mise à jour."
            git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
            git -C "$REPO_DIR" fetch --tags --force origin
        else
            die "'$REPO_DIR' existe déjà mais n'est pas marqué comme un clone créé par bench-rf2.sh (fichier '$marker' absent). Par sécurité, ce script refuse d'y exécuter checkout --force / reset --hard / clean -fdx : ce pourrait être un checkout de travail existant. Pointez --dir/BENCH_RF2_DIR vers un répertoire dédié et vide, ou, si vous êtes certain·e que ce répertoire ne contient rien d'important, supprimez-le vous-même avant de relancer."
        fi
    else
        log "  clone initial depuis $REPO_URL"
        git clone "$REPO_URL" "$REPO_DIR"
        touch "$marker"
    fi

    # On tente de récupérer le ref explicitement (utile s'il s'agit d'un SHA récent
    # non couvert par le fetch précédent sur certains miroirs peu profonds).
    git -C "$REPO_DIR" fetch origin "$REF" 2>/dev/null || true

    # Le clone de bench est dédié (marqueur vérifié ci-dessus) : on peut se permettre
    # un reset --hard + clean pour garantir un état strictement identique pour tous
    # les participants. Ceci ne touche JAMAIS un checkout de travail personnel —
    # uniquement ce clone marqué sous $BENCH_DIR. Le marqueur est exclu du clean pour
    # survivre aux runs suivants.
    git -C "$REPO_DIR" checkout --force --detach "$REF" \
        || die "Impossible de checkout le ref '$REF'. Vérifiez --ref ou la connectivité réseau."
    git -C "$REPO_DIR" reset --hard "$REF"
    git -C "$REPO_DIR" clean -fdx -e .bench-rf2-clone

    local head_sha
    head_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
    log "  HEAD du clone de bench: $head_sha"
}

# ---------------------------------------------------------------------------
# 4. Collecte des informations machine
# ---------------------------------------------------------------------------

CPU_MODEL="inconnu"
CPU_PHYS_CORES="inconnu"
CPU_LOGICAL_CORES="inconnu"
RAM_TOTAL="inconnu"
OS_DESC="inconnu"
JDK_DESC="inconnu"
DISK_TYPE="inconnu"
GRADLE_VERSION="inconnu"
AGP_VERSION="inconnu"
KOTLIN_VERSION="inconnu"
KSP_VERSION="inconnu"
HILT_VERSION="inconnu"
TIME_BIN=""

strip_partition_suffix() {
    # nvme0n1p3 -> nvme0n1 ; mmcblk0p1 -> mmcblk0 ; sda1 -> sda ; dm-0 -> dm-0 (pas de partition).
    local dev="$1"
    if [[ -d "/sys/block/$dev" ]]; then
        printf '%s' "$dev"
    elif [[ "$dev" =~ ^(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)p[0-9]+$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$dev" =~ ^([a-zA-Z]+)[0-9]+$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$dev"
    fi
}

resolve_underlying_block_dev() {
    # Descend au travers de LUKS/LVM/mdraid (via /sys/class/block/<dev>/slaves/) pour
    # atteindre un device physique. Sur une grappe multi-disques, ne suit que le
    # premier slave rencontré (approximation documentée dans le README).
    local dev="$1"
    local depth=0
    while [[ -d "/sys/class/block/$dev/slaves" && $depth -lt 6 ]]; do
        local slaves=(/sys/class/block/"$dev"/slaves/*)
        [[ -e "${slaves[0]}" ]] || break
        dev="$(basename "${slaves[0]}")"
        depth=$(( depth + 1 ))
    done
    printf '%s' "$dev"
}

detect_disk_type() {
    local target_dir="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        local info
        info="$(diskutil info / 2>/dev/null || true)"
        if printf '%s' "$info" | grep -qi "Solid State: *Yes"; then
            echo "SSD (macOS, diskutil)"
        elif printf '%s' "$info" | grep -qi "Solid State: *No"; then
            echo "HDD (macOS, diskutil)"
        else
            echo "inconnu (macOS)"
        fi
        return
    fi

    local src dev rota
    src="$(df -P "$target_dir" 2>/dev/null | tail -n1 | awk '{print $1}' || true)"
    dev="$(basename "$(readlink -f "$src" 2>/dev/null || echo "$src")")"
    dev="$(resolve_underlying_block_dev "$dev")"
    dev="$(strip_partition_suffix "$dev")"
    if [[ -r "/sys/block/$dev/queue/rotational" ]]; then
        rota="$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null || echo "")"
        case "$rota" in
            0) echo "SSD/NVMe (rotational=0, /dev/$dev)" ;;
            1) echo "HDD (rotational=1, /dev/$dev)" ;;
            *) echo "inconnu (/dev/$dev)" ;;
        esac
    else
        echo "inconnu (non détectable pour /dev/$dev — LVM/RAID multi-disque possible)"
    fi
}

collect_machine_info() {
    log "Collecte des informations machine..."

    local uname_s
    uname_s="$(uname -s)"

    if [[ "$uname_s" == "Darwin" ]]; then
        CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo inconnu)"
        CPU_PHYS_CORES="$(sysctl -n hw.physicalcpu 2>/dev/null || echo inconnu)"
        CPU_LOGICAL_CORES="$(sysctl -n hw.logicalcpu 2>/dev/null || echo inconnu)"
        local ram_bytes
        ram_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
        RAM_TOTAL="$(( ram_bytes / 1024 / 1024 / 1024 )) Go"
        OS_DESC="macOS $(sw_vers -productVersion 2>/dev/null || echo '?') ($(uname -r))"
    else
        # Sondes optionnelles, blindées vis-à-vis de `set -euo pipefail` : sur
        # certains Linux (notamment ARM), /proc/cpuinfo n'a pas de champ
        # "model name" — grep y renvoie alors 1, et sans le `|| true` ci-dessous ce
        # statut non nul (repris par le pipeline entier via pipefail) ferait quitter
        # tout le script avant même d'atteindre le fallback "inconnu".
        CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/^.*: //' || true)"
        [[ -z "$CPU_MODEL" ]] && CPU_MODEL="inconnu"
        if command -v lscpu >/dev/null 2>&1; then
            CPU_PHYS_CORES="$(lscpu -p=Core,Socket 2>/dev/null | grep -v '^#' | sort -u | wc -l || true)"
            [[ -z "$CPU_PHYS_CORES" || "$CPU_PHYS_CORES" == "0" ]] && CPU_PHYS_CORES="inconnu"
        fi
        CPU_LOGICAL_CORES="$(nproc --all 2>/dev/null || echo inconnu)"
        if command -v free >/dev/null 2>&1; then
            RAM_TOTAL="$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || true)"
            [[ -z "$RAM_TOTAL" ]] && RAM_TOTAL="inconnu"
        fi
        if [[ -r /etc/os-release ]]; then
            local pretty_name=""
            # Sous-coquille dédiée avec `set +eu` : si /etc/os-release ne définit pas
            # PRETTY_NAME, une expansion directe "$PRETTY_NAME" sous `set -u` (hérité
            # sinon dans la substitution de commande) tuerait la sous-coquille AVANT
            # que le `|| true` externe ou le fallback ne puissent agir. `${PRETTY_NAME:-}`
            # neutralise déjà le cas nounset ; `set +eu` blinde aussi contre un
            # sourcing en échec ou toute autre variable non définie dans le fichier.
            pretty_name="$( (set +eu; . /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}") 2>/dev/null || true )"
            if [[ -n "$pretty_name" ]]; then
                OS_DESC="$pretty_name ($(uname -r))"
            else
                OS_DESC="Linux $(uname -r)"
            fi
        else
            OS_DESC="Linux $(uname -r)"
        fi
    fi

    JDK_DESC="$(java -version 2>&1 | head -n1)"
    DISK_TYPE="$(detect_disk_type "$BENCH_DIR")"

    if command -v /usr/bin/time >/dev/null 2>&1 && /usr/bin/time -v true >/dev/null 2>&1; then
        TIME_BIN="/usr/bin/time"
    else
        warn "/usr/bin/time -v indisponible (normal sur macOS sans GNU time / 'brew install gnu-time') — le pic RSS ne sera pas mesuré."
    fi

    pushd "$REPO_DIR" >/dev/null
    # Ce ./gradlew --version sert aussi de warm-up réseau : c'est lui qui télécharge
    # la distribution Gradle (wrapper) si elle n'est pas déjà en cache, HORS
    # chronométrage — il s'exécute ici, avant tout appel à run_scenario (S1 inclus)
    # dans run_all_scenarios. Le scénario S1 ne paie donc pas ce coût réseau.
    GRADLE_VERSION="$(./gradlew --version 2>/dev/null | awk '/^Gradle /{print $2}' || true)"
    [[ -z "$GRADLE_VERSION" ]] && GRADLE_VERSION="inconnu"
    if [[ -f gradle/libs.versions.toml ]]; then
        AGP_VERSION="$(grep -E '^agp *=' gradle/libs.versions.toml | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        KOTLIN_VERSION="$(grep -E '^kotlin *=' gradle/libs.versions.toml | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        KSP_VERSION="$(grep -E '^ksp *=' gradle/libs.versions.toml | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        HILT_VERSION="$(grep -E '^hilt *=' gradle/libs.versions.toml | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || true)"
        [[ -z "$AGP_VERSION" ]] && AGP_VERSION="inconnu"
        [[ -z "$KOTLIN_VERSION" ]] && KOTLIN_VERSION="inconnu"
        [[ -z "$KSP_VERSION" ]] && KSP_VERSION="inconnu"
        [[ -z "$HILT_VERSION" ]] && HILT_VERSION="inconnu"
    fi
    popd >/dev/null

    log "  CPU: $CPU_MODEL ($CPU_PHYS_CORES phys / $CPU_LOGICAL_CORES logiques)"
    log "  RAM: $RAM_TOTAL"
    log "  OS: $OS_DESC"
    log "  JDK: $JDK_DESC"
    log "  Disque: $DISK_TYPE"
    log "  Gradle $GRADLE_VERSION / AGP $AGP_VERSION / Kotlin $KOTLIN_VERSION / KSP $KSP_VERSION / Hilt $HILT_VERSION"
}

# ---------------------------------------------------------------------------
# 5. Exécution chronométrée des scénarios
# ---------------------------------------------------------------------------

SCENARIO_IDS=()
SCENARIO_LABELS=()
SCENARIO_SECONDS=()
SCENARIO_RSS_MB=()
SCENARIO_STATUS=()

# run_scenario <id> <label humain> -- <commande...>
run_scenario() {
    local id="$1" label="$2"
    shift 2
    [[ "$1" == "--" ]] && shift

    log "=== $id: $label ==="
    log "    commande: $*"

    ./gradlew --stop >/dev/null 2>&1 || true

    local status=0
    local rss_mb="n/a"
    local time_log="$RUN_LOG_DIR/${id}.time.log"
    local out_log="$RUN_LOG_DIR/${id}.out.log"
    local err_log="$RUN_LOG_DIR/${id}.err.log"

    SECONDS=0
    if [[ -n "$TIME_BIN" ]]; then
        # -o écrit les métriques GNU time DANS time_log et seulement elles : le
        # stdout/stderr de la commande benchée (Gradle) va dans out_log/err_log,
        # jamais mélangé aux métriques. Sans -o, GNU time écrit ses métriques sur
        # stderr — c'est ce qui écrasait auparavant le stderr réel de Gradle dans
        # time_log, alors que le diagnostic d'échec ci-dessous pointait vers out_log.
        if "$TIME_BIN" -v -o "$time_log" "$@" >"$out_log" 2>"$err_log"; then
            status=0
        else
            status=$?
        fi
        local rss_kb
        rss_kb="$(grep 'Maximum resident set size' "$time_log" 2>/dev/null | awk -F': ' '{print $2}' | tr -dc '0-9' || true)"
        if [[ -n "$rss_kb" ]]; then
            rss_mb="$(( rss_kb / 1024 )) Mo"
        fi
    else
        if "$@" >"$out_log" 2>"$err_log"; then
            status=0
        else
            status=$?
        fi
    fi
    local elapsed=$SECONDS

    if [[ $status -ne 0 ]]; then
        warn "  scénario $id: commande terminée en échec (code $status) — voir $err_log (stderr) et $out_log (stdout). Le temps est quand même consigné."
    fi

    log "  -> ${elapsed}s (RSS pic: $rss_mb, statut: $status)"

    SCENARIO_IDS+=("$id")
    SCENARIO_LABELS+=("$label")
    SCENARIO_SECONDS+=("$elapsed")
    SCENARIO_RSS_MB+=("$rss_mb")
    SCENARIO_STATUS+=("$status")
}

run_all_scenarios() {
    pushd "$REPO_DIR" >/dev/null
    # GRADLE_USER_HOME déjà exporté en tête de script (voir plus haut).

    # S1 — configuration + build-logic : purge du cache de configuration LOCAL au
    # projet puis `help`. ATTENTION : `help` construit le graphe de tâches mais peut
    # aussi déclencher la (re)compilation de l'included build `build-logic` si son
    # cache est invalide — ce n'est donc PAS de la « configuration Gradle pure ».
    # Ceci n'est pas non plus un cold start complet : le démon Gradle est frais
    # (--stop) mais le cache de dépendances ($GRADLE_USER_HOME) reste chaud, et la
    # distribution Gradle elle-même a déjà été téléchargée hors chronométrage par le
    # `./gradlew --version` de collect_machine_info (voir plus haut) — S1 ne paie
    # donc pas ce coût réseau.
    rm -rf .gradle/configuration-cache build-logic/.gradle/configuration-cache
    run_scenario "S1" "configuration + build-logic (./gradlew help, cache de configuration purgé)" -- \
        ./gradlew help

    # S2 — clean build de la variante canonique de l'app (assembleDebug non
    # flavoré ne résout pas : le module :app a la dimension de flavor "channel").
    run_scenario "S2" "clean build (./gradlew clean :app:assembleProdDebug --no-build-cache)" -- \
        ./gradlew clean :app:assembleProdDebug --no-build-cache

    # S3 — réexécution immédiate, sans clean : mesure le coût des vérifications
    # up-to-date / de l'incrémentalité Gradle, démon à nouveau frais (--stop dans
    # run_scenario) mais sorties de build de S2 encore sur disque.
    run_scenario "S3" "warm no-op (même commande que S2, sans clean)" -- \
        ./gradlew :app:assembleProdDebug --no-build-cache

    # S4 — tests unitaires : tâches réellement utilisées par la CI
    # (.github/workflows/ci.yml, matrix "test"): `test` couvre les modules JVM purs
    # (core:model, core:domain, core:parser, ...) + agrège les variantes de :app
    # (incl. le test Konsist d'architecture) ; `testDebugUnitTest` couvre les
    # modules Android non flavorés (core:database, core:ui, core:network,
    # core:data, core:extension, feature:*).
    run_scenario "S4" "tests unitaires (./gradlew test testDebugUnitTest, comme la CI)" -- \
        ./gradlew test testDebugUnitTest

    if [[ $FULL_RUN -eq 1 ]]; then
        # S5a — detekt : `detektAll` est une tâche générique (dependsOn) qui délègue
        # à `detektCliCheck`, la véritable tâche JavaExec (définie dans le
        # build.gradle.kts racine), laquelle lance detekt-cli en UNE passe sur tout
        # le repo (pas une agrégation par module).
        run_scenario "S5a" "detekt (./gradlew detektAll, comme la CI)" -- \
            ./gradlew detektAll

        # S5b — lint : `lintDebug` couvre les modules non flavorés, `:app:lintProdDebug`
        # est nécessaire en plus car :app est flavoré (channel) et lintDebug seul n'y
        # résout pas de variante.
        run_scenario "S5b" "lint (./gradlew lintDebug :app:lintProdDebug, comme la CI)" -- \
            ./gradlew lintDebug :app:lintProdDebug
    fi

    ./gradlew --stop >/dev/null 2>&1 || true
    popd >/dev/null
}

# ---------------------------------------------------------------------------
# 6. Génération du bloc de résultats (Markdown + BBCode)
# ---------------------------------------------------------------------------

render_results() {
    local head_sha
    head_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
    local now_utc
    now_utc="$(date -u +'%Y-%m-%d %H:%M UTC')"
    local full_label="non"
    [[ $FULL_RUN -eq 1 ]] && full_label="oui"

    local md_file="$RUN_LOG_DIR/resultats.md"
    local bb_file="$RUN_LOG_DIR/resultats.bbcode.txt"

    {
        echo "### Résultat bench Redface 2 — $now_utc"
        echo
        echo "- Script bench-rf2.sh version: $SCRIPT_VERSION"
        echo "- Ref benchmarké: $REF_LABEL (commit \`$head_sha\`)"
        echo "- Scénario --full: $full_label"
        echo
        echo "| Info machine | Valeur |"
        echo "|---|---|"
        echo "| CPU | $CPU_MODEL |"
        echo "| Cœurs physiques / logiques | $CPU_PHYS_CORES / $CPU_LOGICAL_CORES |"
        echo "| RAM totale | $RAM_TOTAL |"
        echo "| OS | $OS_DESC |"
        echo "| JDK | $JDK_DESC |"
        echo "| Disque | $DISK_TYPE |"
        echo "| Gradle / AGP / Kotlin / KSP / Hilt | $GRADLE_VERSION / $AGP_VERSION / $KOTLIN_VERSION / $KSP_VERSION / $HILT_VERSION |"
        echo
        echo "| Scénario | Description | Temps réel | Pic RSS | Statut |"
        echo "|---|---|---|---|---|"
        local i
        for i in "${!SCENARIO_IDS[@]}"; do
            local st="OK"
            [[ "${SCENARIO_STATUS[$i]}" != "0" ]] && st="ÉCHEC (${SCENARIO_STATUS[$i]})"
            echo "| ${SCENARIO_IDS[$i]} | ${SCENARIO_LABELS[$i]} | ${SCENARIO_SECONDS[$i]}s | ${SCENARIO_RSS_MB[$i]} | $st |"
        done
    } > "$md_file"

    {
        echo "[fixed]"
        echo "Bench Redface 2 — $now_utc"
        echo "Ref: $REF_LABEL ($head_sha) | --full: $full_label"
        echo "CPU: $CPU_MODEL"
        echo "Coeurs phys/log: $CPU_PHYS_CORES / $CPU_LOGICAL_CORES | RAM: $RAM_TOTAL | Disque: $DISK_TYPE"
        echo "OS: $OS_DESC"
        echo "JDK: $JDK_DESC"
        echo "Gradle $GRADLE_VERSION / AGP $AGP_VERSION / Kotlin $KOTLIN_VERSION / KSP $KSP_VERSION / Hilt $HILT_VERSION"
        echo "---"
        local i
        for i in "${!SCENARIO_IDS[@]}"; do
            local st="OK"
            [[ "${SCENARIO_STATUS[$i]}" != "0" ]] && st="ECHEC(${SCENARIO_STATUS[$i]})"
            printf '%-4s %-70s %8s  RSS=%-10s %s\n' \
                "${SCENARIO_IDS[$i]}" "${SCENARIO_LABELS[$i]}" "${SCENARIO_SECONDS[$i]}s" "${SCENARIO_RSS_MB[$i]}" "$st"
        done
        echo "[/fixed]"
    } > "$bb_file"

    log ""
    log "Résultats écrits dans:"
    log "  $md_file"
    log "  $bb_file"
    log ""
    log "=================== BLOC MARKDOWN ==================="
    cat "$md_file"
    log "=================== BLOC BBCODE HFR ==================="
    cat "$bb_file"
    log "======================================================="
    log ""
    log "Copiez-collez le bloc de votre choix pour le partager. Ce script n'envoie rien lui-même."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
    log "bench-rf2.sh v$SCRIPT_VERSION — répertoire de travail: $BENCH_DIR"
    check_prereqs
    setup_repo
    collect_machine_info
    run_all_scenarios
    render_results
}

main "$@"
