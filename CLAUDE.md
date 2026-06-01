# immich-auto-dumper — CLAUDE.md

Outil de backup automatique pour Immich (auto-hébergé, déployé via Docker sur Linux).
Ce fichier est la source de vérité pour toute session de développement.

---

## Objectif

`immich-auto-dumper` est un script Bash généraliste qui gère deux politiques de
sauvegarde pour une instance Immich :

1. **Copie des backups de base de données** : Immich génère automatiquement des dumps
   PostgreSQL dans `UPLOAD_LOCATION/backups/`. Le script copie ces fichiers vers un
   dossier `.immich-backup/` situé à la racine du stockage externe, et en gère la
   rétention.

2. **Archivage automatique des photos** : quand le dossier `library/` dépasse un seuil
   de remplissage configurable, le script déplace les photos les plus anciennes vers
   un stockage externe (monté localement et accessible par Immich comme bibliothèque
   externe), en mettant à jour la base de données Immich pour que les assets restent
   accessibles sans perte de métadonnées.

**Structure du stockage externe :**
```
/stockage_externe/
  .immich-backup/              ← dumps BDD copiés depuis Immich
    immich_2025-06-01.sql.gz
    immich_2025-06-02.sql.gz
  Utilisateur_1/               ← photos archivées
    2022/06/...
  Utilisateur_2/
    2023/04/...
```

---

## Contraintes générales

- **Généraliste** : aucune référence à un fournisseur de stockage, un service réseau,
  ou une configuration personnelle dans le code. Les chemins, noms de conteneurs,
  credentials sont tous dans `config.conf` (gitignored).
- **Bash strict mode** : `set -euo pipefail` dans tous les fichiers.
- **Atomicité** : aucune suppression de fichier source sans vérification préalable de
  la présence du fichier à destination ET de la mise à jour réussie de la BDD.
- **Idempotence** : une exécution interrompue puis relancée ne doit pas créer d'état
  incohérent.
- **Compatibilité** : Ubuntu 22.04+, Debian 12+. Dépendances : `docker`, `jq`,
  `bc`, `curl`.

---

## Architecture des fichiers

```
immich-auto-dumper/
├── immich-auto-dumper.sh    # Point d'entrée CLI
├── install.sh               # Installateur one-liner
├── config.conf.example      # Template de configuration (versionné)
├── config.conf              # Configuration réelle (gitignored)
├── CLAUDE.md                # Ce fichier
├── README.md
├── cron/
│   └── crontab.example
└── lib/
    ├── utils.sh             # Logging, checks prérequis, helpers disque
    ├── db.sh                # Requêtes PostgreSQL via docker exec
    ├── backup_db.sh         # Volet 1 : copie des backups BDD vers stockage externe
    └── archive.sh           # Volet 2 : archivage photos avec mise à jour BDD
```

Chaque fichier `lib/*.sh` est sourcé par `immich-auto-dumper.sh`. Ils n'ont pas de
bloc principal, uniquement des fonctions.

---

## config.conf — Variables et structure

```bash
# --- Immich ---
IMMICH_UPLOAD_LOCATION="/path/to/immich/library"  # Chemin vers UPLOAD_LOCATION
IMMICH_DB_CONTAINER="immich_postgres"
IMMICH_SERVER_CONTAINER="immich_server"
IMMICH_DB_NAME="immich"
IMMICH_DB_USER="postgres"
IMMICH_API_URL="http://localhost:2283"
IMMICH_API_KEY=""

# --- Stockage externe (destination pour photos archivées ET backups BDD) ---
ARCHIVE_DEST_PATH="/mnt/external"  # Chemin local du stockage externe,
                                   # accessible par le conteneur immich_server
ARCHIVE_CONTAINER_PATH="/external" # Même chemin vu depuis le conteneur Docker
# Les backups BDD seront dans : $ARCHIVE_DEST_PATH/.immich-backup/
# Les photos archivées :        $ARCHIVE_DEST_PATH/<NomUtilisateur>/YYYY/MM/...

# --- Archivage photos ---
ARCHIVE_THRESHOLD_HIGH=60          # % déclenchement archivage
ARCHIVE_THRESHOLD_LOW=40           # % cible après archivage

# --- Backup BDD ---
BACKUP_RETENTION=14                # Nombre de fichiers backup à conserver

# --- Correspondance userID/storage_label → nom de dossier sur le stockage externe ---
# Générée automatiquement par "setup", modifiable manuellement.
# Format : USER_MAP["storage_label_ou_uuid"]="nom_dossier"
declare -A USER_MAP

# --- Logs ---
LOG_DIR="/var/log/immich-auto-dumper"
LOG_MAX_LINES=1000
```

---

## lib/utils.sh

Fonctions :

- `log_info <message>` / `log_warn <message>` / `log_error <message>`
  Format : `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
  Sortie : stdout (coloré si TTY) + fichier `$LOG_DIR/immich-auto-dumper.log`

- `check_prereqs`
  Vérifie la présence de : `docker`, `jq`, `bc`, `curl`
  Quitte avec code 1 et message explicite si un outil manque.

- `check_archive_dest_mounted`
  Vérifie que `ARCHIVE_DEST_PATH` est un point de montage actif (`mountpoint -q`).
  Retourne 0 si monté, 1 sinon. Ne quitte pas — l'appelant décide du comportement.

- `disk_usage_percent <path>`
  Retourne le pourcentage d'utilisation du système de fichiers contenant `<path>`.
  Utilise `df --output=pcent <path> | tail -1 | tr -d ' %'`.

- `bytes_to_human <bytes>`
  Convertit un nombre d'octets en chaîne lisible (Ko, Mo, Go).

- `acquire_lock` / `release_lock`
  Fichier lock : `/tmp/immich-auto-dumper.lock`
  `acquire_lock` échoue si le lock existe et que le PID est encore actif.

---

## lib/db.sh

Toutes les requêtes passent par :
```bash
docker exec -i "$IMMICH_DB_CONTAINER" psql \
  -U "$IMMICH_DB_USER" -d "$IMMICH_DB_NAME" -t -A -c "<SQL>"
```

Fonctions :

- `db_get_users`
  Retourne les utilisateurs Immich : id, name, storage_label.
  SQL : `SELECT id, name, storage_label FROM users ORDER BY created_at`
  Sortie : une ligne par user, champs séparés par `|`

- `db_get_month_folder_assets <user_folder> <year> <month>`
  Retourne tous les assets d'un user pour un mois donné (année/mois extraits du
  `original_path`). Permet de travailler par dossier mensuel complet.
  Retourne : `id|original_path|file_size`

- `db_get_archive_candidates`
  Retourne la liste des dossiers mensuels candidats à l'archivage, triés par
  date ASC. Un dossier mensuel est identifié par (user_folder, year, month).
  Critères d'exclusion :
  - `original_path` commençant déjà par `ARCHIVE_CONTAINER_PATH` (déjà archivé)
  - `is_offline = true`
  - `is_trashed = true`
  SQL retourne : `user_folder|year|month|total_size`

- `db_update_asset_path <asset_id> <new_path>`
  Met à jour `original_path` dans une transaction.
  Retourne 0 si succès, 1 si échec.
  SQL : `BEGIN; UPDATE assets SET original_path='<new_path>' WHERE id='<id>'; COMMIT;`

- `db_get_sidecar_path <asset_id>`
  Retourne `sidecar_path` si non null, sinon chaîne vide.

---

## lib/backup_db.sh

Fonction principale : `backup_db_run`

```
1. check_prereqs
2. check_archive_dest_mounted → si non monté : log_warn + return 0 (silencieux)
3. Vérifier que $IMMICH_UPLOAD_LOCATION/backups/ existe et contient des fichiers
4. Créer $ARCHIVE_DEST_PATH/.immich-backup/ s'il n'existe pas
5. POUR CHAQUE fichier dans $IMMICH_UPLOAD_LOCATION/backups/ :
   - cp "$src" "$ARCHIVE_DEST_PATH/.immich-backup/"
   - Loguer le fichier copié
6. Rotation : lister les fichiers dans .immich-backup/, trier par date de modification
   Si nombre de fichiers > BACKUP_RETENTION :
   - Supprimer les plus anciens jusqu'à atteindre BACKUP_RETENTION fichiers
   - Loguer les suppressions
7. Loguer : nombre de fichiers conservés, taille totale
```

Les deux opérations (photos et backups BDD) utilisent des copies locales (`cp`) car
le stockage externe est accessible directement via le système de fichiers du serveur.
Si l'utilisateur souhaite ensuite synchroniser ce stockage vers un système distant,
c'est un choix indépendant de cet outil.

Immich génère automatiquement ses backups. Ce script se contente de les mirroiter
vers le stockage externe et d'en gérer la rétention.

---

## lib/archive.sh

### Principe d'archivage par dossier mensuel complet

L'unité d'archivage est le **dossier mensuel** (`<year>/<month>/`) d'un utilisateur,
pas le fichier individuel. On n'archive jamais un dossier partiellement — si
l'objectif de libération est atteint en cours de dossier, on termine quand même le
dossier en cours avant de s'arrêter.

### Fonction helper : `archive_build_dest_path <original_path>`

Construit le chemin de destination dans le stockage externe à partir du chemin
source dans `library/`.

**Logique :**
```
original_path = $IMMICH_UPLOAD_LOCATION/library/<user_folder>/<year>/<month>/<file>
```
1. Extraire `<user_folder>` (premier segment après `library/`)
2. Résoudre le nom de dossier externe via `USER_MAP["<user_folder>"]`
   (si absent de la map → utiliser `<user_folder>` tel quel)
3. Extraire `<year>`, `<month>`, `<file>`
4. Retourner : `$ARCHIVE_DEST_PATH/<mapped_name>/<year>/<month>/<file>`

**Exemple :**
```
original_path   = /immich/library/admin/2022/02/2022 February 03 - IMG.jpg
USER_MAP[admin] = "Jules"
→ résultat      = /mnt/external/Jules/2022/02/2022 February 03 - IMG.jpg
```

### Algorithme principal : `archive_run`

```
archive_run() {
  1. check_prereqs
  2. check_archive_dest_mounted → si non monté : log_warn + return 0 (silencieux)
  3. acquire_lock → si lock actif : log_warn + return 0
  4. usage=$(disk_usage_percent "$IMMICH_UPLOAD_LOCATION/library/")
     si usage < ARCHIVE_THRESHOLD_HIGH → log_info "Espace suffisant" + return 0

  5. Calculer bytes_to_free :
     total=$(df --output=size "$IMMICH_UPLOAD_LOCATION" | tail -1)  # en Ko
     bytes_to_free = (usage - ARCHIVE_THRESHOLD_LOW) / 100 * total * 1024

  6. freed_bytes=0
     candidates = db_get_archive_candidates()
     # Liste de tuples (user_folder, year, month, folder_size) triés par date ASC

  7. POUR CHAQUE dossier mensuel (user_folder, year, month, folder_size) :

     a. assets = db_get_month_folder_assets(user_folder, year, month)
     b. POUR CHAQUE asset dans le dossier :
        i.   src_path  = chemin local du fichier
        ii.  dst_local = archive_build_dest_path(original_path)
        iii. Créer le répertoire destination si nécessaire (mkdir -p)
        iv.  cp "$src_path" "$dst_local"
        v.   Vérifier présence dst_local : stat "$dst_local"
             → si échec : log_error + continue (skip cet asset)
        vi.  dst_container = dst_local avec ARCHIVE_DEST_PATH → ARCHIVE_CONTAINER_PATH
        vii. db_update_asset_path(asset_id, dst_container)
             → si échec : log_error + rm "$dst_local" + continue
        viii.Vérifier accès depuis conteneur :
             docker exec "$IMMICH_SERVER_CONTAINER" test -f "$dst_container"
             → si échec : log_error + rollback BDD + rm "$dst_local" + continue
        ix.  rm "$src_path"
        x.   sidecar=$(db_get_sidecar_path asset_id)
             si sidecar non vide → même séquence iv→ix pour le fichier sidecar
        xi.  freed_bytes += file_size

     c. log_info "Dossier archivé : $user_folder/$year/$month — $(bytes_to_human folder_size)"

     # On termine toujours le dossier en cours même si l'objectif est atteint.
     # On vérifie le seuil APRÈS avoir terminé un dossier complet.
     d. si freed_bytes >= bytes_to_free → break

  8. Déclencher rescan de la bibliothèque externe via API Immich :
     - GET $IMMICH_API_URL/api/libraries → extraire l'id de la bibliothèque externe
     - POST $IMMICH_API_URL/api/libraries/<lib_id>/scan
     En-tête : "x-api-key: $IMMICH_API_KEY"

  9. release_lock
  10. log_info "Archivage terminé. Libéré : $(bytes_to_human freed_bytes)"
}
```

**Note sur le rescan :** la doc Immich indique que si un fichier d'une bibliothèque
externe disparaît, Immich le marque offline puis le met à la corbeille au prochain
scan, ce qui entraîne la perte des métadonnées (albums, descriptions, faces).
Ici on met à jour `original_path` en BDD AVANT le rescan : Immich retrouve le
fichier à son nouveau chemin sans doublon ni perte de métadonnées. Le rescan final
sert uniquement à rafraîchir les caches et vignettes.

---

## immich-auto-dumper.sh — CLI

Usage :
```
immich-auto-dumper <commande>

Commandes :
  setup       Configuration assistée (création ou mise à jour de config.conf)
  status      État du service, espace disque, dernières opérations
  start       Active les crons
  stop        Désactive les crons, attend la fin de l'opération en cours
  dump_now    Force un archivage immédiat jusqu'au seuil bas
  sync_now    Force une copie immédiate des backups BDD vers le stockage externe
```

### setup

Wizard interactif. Fonctionne en création ET en mise à jour : charge `config.conf`
existant si présent et pré-remplit toutes les valeurs actuelles.

Étapes :
1. Détecter les conteneurs Docker Immich actifs (propose des valeurs par défaut)
2. Demander `IMMICH_UPLOAD_LOCATION`
3. Demander `ARCHIVE_DEST_PATH` et `ARCHIVE_CONTAINER_PATH`
4. Demander `IMMICH_API_URL` et `IMMICH_API_KEY`
5. **Détection automatique des users** :
   Lancer `db_get_users` → afficher la liste avec id / name / storage_label
   Pour chaque user : proposer un nom de dossier (pré-rempli avec storage_label
   ou name), permettre à l'utilisateur de corriger
6. Demander `ARCHIVE_THRESHOLD_HIGH` et `ARCHIVE_THRESHOLD_LOW`
7. Demander `BACKUP_RETENTION`
8. Afficher un récapitulatif et demander confirmation
9. Écrire `config.conf`
10. Proposer d'installer les crons (affiche le crontab, demande confirmation)

### status

Affichage formaté :
```
=== immich-auto-dumper status ===
Espace library/      : 45% utilisé  [seuil haut: 60% — seuil bas: 40%]
Stockage externe     : monté  (/mnt/external)
Backups BDD          : 8 fichiers dans .immich-backup/
Crons                : actifs
Dernière archive     : 2025-06-01 02:00 — 3,2 Go libérés
Dernier backup BDD   : 2025-06-01 03:00 — OK
Lock                 : inactif
```

### start / stop

`start` : lit les entrées cron depuis `cron/crontab.example` et les ajoute au
crontab de l'utilisateur courant (sans écraser les entrées existantes).

`stop` : commente les lignes `immich-auto-dumper` dans le crontab de l'utilisateur.
Vérifie le lock et attend (max 60s) la fin de l'opération en cours avant de retourner.

---

## install.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/immich-auto-dumper}"
REPO="https://github.com/de-seingalt/immich-auto-dumper.git"

# 1. Vérifier que git et curl sont disponibles
# 2. git clone si première installation, git pull si déjà installé
# 3. chmod +x immich-auto-dumper.sh
# 4. Créer un lien symbolique : /usr/local/bin/immich-auto-dumper
# 5. Lancer : immich-auto-dumper setup
```

One-liner d'installation :
```bash
curl -fsSL https://raw.githubusercontent.com/de-seingalt/immich-auto-dumper/main/install.sh | bash
```

---

## cron/crontab.example

```cron
# immich-auto-dumper — archivage automatique (quotidien à 2h)
0 2 * * * /usr/local/bin/immich-auto-dumper dump_now >> /var/log/immich-auto-dumper/cron.log 2>&1

# immich-auto-dumper — copie des backups BDD (hebdomadaire, dimanche à 3h)
0 3 * * 0 /usr/local/bin/immich-auto-dumper sync_now >> /var/log/immich-auto-dumper/cron.log 2>&1
```

---

## Conventions de développement

- Toute fonction est préfixée par le nom de son module : `utils_*`, `db_*`,
  `backup_*`, `archive_*`.
- Les variables locales sont déclarées avec `local`.
- Les messages d'erreur vont sur stderr : `log_error "..." >&2`
- Les codes de retour sont explicites : `return 0` (succès) / `return 1` (échec).
- Pas de `exit` dans les fonctions de lib — uniquement dans le point d'entrée CLI.
- Tout chemin de fichier est entre guillemets doubles.
- Les commentaires expliquent le POURQUOI, pas le QUOI.

---

## Ordre de développement

Respecter cet ordre pour garantir que les dépendances sont disponibles à chaque étape :

1. `lib/utils.sh`
2. `lib/db.sh`
3. `lib/backup_db.sh`
4. `lib/archive.sh`
5. `immich-auto-dumper.sh`
6. `install.sh`
7. `config.conf.example`, `cron/crontab.example`, `README.md`
