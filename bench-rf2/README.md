# bench-rf2 — kit de benchmark communautaire Gradle pour Redface 2

Kit auto-suffisant pour permettre à des contributeurs/membres du forum de bencher leur
machine (CPU/RAM/disque) sur les builds Gradle du projet
[ForumHFR/redface2](https://github.com/ForumHFR/redface2), sans rien exécuter chez le
mainteneur ni rien publier automatiquement.

## Contenu du dossier

- `bench-rf2.sh` — script bash (Linux/macOS) qui clone une copie dédiée du dépôt sur un
  ref fixe, collecte les infos machine, exécute 4 (ou 5 avec `--full`) scénarios Gradle
  chronométrés, et affiche un bloc de résultats copiable en Markdown et en BBCode HFR.
  Ne clone/écrit que sous son propre répertoire de travail (`~/.cache/bench-rf2` par
  défaut, ou `$BENCH_RF2_DIR`) — ne touche jamais un checkout de travail existant. Ne
  publie/n'uploade rien : la soumission du résultat est un copier-coller manuel.
- `index.html` — page statique autonome (aucune ressource externe, thème clair/sombre),
  en français, qui explique le protocole et sert de point d'entrée pour un contributeur.
- `README.md` — ce fichier.

## Publier sur ForumHFR/artifacts

La page est prévue pour être servie sous
`https://forumhfr.github.io/artifacts/bench-rf2/`, avec `bench-rf2.sh` accessible en
relatif à côté d'`index.html` (le lien de téléchargement dans la page suppose ce chemin).

1. Cloner/mettre à jour un checkout local de `ForumHFR/artifacts`.
2. Copier tout le dossier `bench-rf2/` (les 3 fichiers) vers `artifacts/bench-rf2/` dans
   ce dépôt (chemin suggéré : à la racine du site Pages, sous `bench-rf2/`).
3. Committer et pousser sur la branche servie par GitHub Pages du dépôt `artifacts`.
4. Vérifier après publication que `bench-rf2.sh` est bien accessible tel quel (pas
   transformé/miniifié) à `https://forumhfr.github.io/artifacts/bench-rf2/bench-rf2.sh` —
   l'instruction `curl -O .../bench-rf2/bench-rf2.sh` de la page en dépend.

Aucune opération git/gh mutante n'a été effectuée pour produire ce kit — la copie vers
`artifacts/` et le push sont à la charge du mainteneur.

## Limites connues du protocole

- **Une seule mesure par run n'est pas une moyenne.** Le script ne répète pas
  automatiquement chaque scénario ; le throttling thermique, d'autres processus, ou un
  antivirus/indexeur en tâche de fond peuvent fausser une mesure isolée. Un participant
  motivé peut relancer `./bench-rf2.sh` plusieurs fois (idempotent) et reporter la
  meilleure/l'ensemble des valeurs.
- **Premier run réseau-dépendant.** Le temps de S1 (et dans une moindre mesure S2)
  inclut potentiellement le téléchargement de la distribution Gradle et des dépendances
  si le cache `$GRADLE_USER_HOME` dédié est vide. Les runs suivants sur la même machine
  n'ont plus ce coût — les résultats d'un tout premier run ne sont donc pas strictement
  comparables à ceux d'un run répété.
- **« Cold configure » (S1) n'est pas un cold start complet.** Seul le cache de
  configuration local au projet (`.gradle/configuration-cache`) est purgé ; le démon
  Gradle est frais (`--stop`) mais le cache de dépendances reste chaud pour éviter un
  téléchargement réseau à chaque itération de bench. Un vrai cold start (VM neuve, aucun
  cache) donnerait des temps S1 plus élevés.
- **Variabilité thermique et énergétique.** Sur laptop, le throttling thermique ou une
  exécution sur batterie change fortement les temps mesurés — la page demande de brancher
  la machine, mais rien ne le vérifie techniquement.
- **Détection du type de disque est une heuristique.** Sur Linux, le script résout le
  périphérique physique sous-jacent via `/sys/class/block/*/slaves` (traverse
  LUKS/LVM/mdraid un niveau à la fois, jusqu'à 6 niveaux). Sur un montage RAID multi-disque,
  seul le premier membre rencontré est reporté — une approximation, pas une garantie
  d'exactitude. Sur macOS, la détection dépend de `diskutil` et peut échouer sur certaines
  configurations (Fusion Drive, volumes chiffrés imbriqués).
- **Pic RSS optionnel.** La mesure du pic de mémoire résidente utilise `/usr/bin/time -v`
  (GNU time). Absent par défaut sur macOS (installable via `brew install gnu-time`), la
  colonne RSS remonte alors `n/a`.
- **`detektAll` n'est pas une agrégation par module.** C'est une tâche `JavaExec` custom
  (définie dans le `build.gradle.kts` racine) qui lance detekt-cli en une seule passe sur
  tout le dépôt — le temps S5a ne se décompose donc pas par module.
- **Ref benchmarké fixe par défaut, mais paramétrable (`--ref`).** Comparer des résultats
  obtenus avec des `--ref` différents n'a pas de sens : la table de résultats de référence
  n'a de valeur que si tout le monde benche le même commit (défaut : `164b6da5`, release
  0.33.0).
- **Le script ne mesure pas l'exécution instrumentée (androidTest/émulateur/device réel).**
  Seuls les tests JVM unitaires (`test` / `testDebugUnitTest`) sont couverts, conformément
  à ce que la CI du projet exécute réellement.
