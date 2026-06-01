# immich-auto-dumper

Outil de backup automatique pour [Immich](https://immich.app/) auto-hébergé sur Linux.

Deux politiques de sauvegarde :

1. **Backup BDD** — copie les dumps PostgreSQL générés par Immich vers un stockage externe et en gère la rétention.
2. **Archivage photos** — quand le dossier `library/` dépasse un seuil configurable, déplace les photos les plus anciennes vers le stockage externe en mettant à jour la base de données Immich, sans perte de métadonnées.

## Prérequis

- Ubuntu 22.04+ ou Debian 12+
- `docker`, `jq`, `bc`, `curl`
- Immich déployé via Docker Compose
- Stockage externe monté localement et accessible par le conteneur `immich_server`

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/de-seingalt/immich-auto-dumper/main/install.sh | bash
```

Installe dans `/opt/immich-auto-dumper` et crée `/usr/local/bin/immich-auto-dumper`, puis lance le wizard de configuration.

Pour choisir un répertoire d'installation différent :

```bash
INSTALL_DIR=/opt/mon-dossier curl -fsSL .../install.sh | bash
```

## Configuration

```bash
immich-auto-dumper setup
```

Le wizard détecte les conteneurs Docker actifs, lit les utilisateurs depuis la BDD et construit la correspondance `storage_label → nom de dossier` sur le stockage externe. Il peut être relancé pour mettre à jour une configuration existante.

Les valeurs sont écrites dans `config.conf` (gitignored). Voir `config.conf.example` pour la structure complète.

### Structure du stockage externe

```
/mnt/external/
  .immich-backup/          ← dumps BDD (miroir de UPLOAD_LOCATION/backups/)
  Alice/                   ← photos archivées, par utilisateur
    2022/06/...
  Bob/
    2023/04/...
```

## Utilisation

```
immich-auto-dumper <commande>

  setup     Configuration assistée
  status    État du service, espace disque, dernières opérations
  start     Active les crons
  stop      Désactive les crons, attend la fin de l'opération en cours
  dump_now  Force un archivage immédiat jusqu'au seuil bas
  sync_now  Force une copie immédiate des backups BDD
```

## Fonctionnement de l'archivage

L'unité d'archivage est le **dossier mensuel** (`<user>/<year>/<month>/`). Un dossier n'est jamais archivé partiellement — si l'objectif de libération est atteint en cours de dossier, l'archivage termine le dossier avant de s'arrêter.

Pour chaque fichier déplacé :
1. Copie vers le stockage externe
2. Vérification de la présence du fichier destination
3. Mise à jour de `original_path` en base de données (transaction)
4. Vérification d'accessibilité depuis le conteneur `immich_server`
5. Suppression du fichier source

En cas d'échec à l'une de ces étapes, la BDD est restaurée à son état précédent et le fichier destination est supprimé. Le fichier source reste intact.

Un rescan de la bibliothèque externe est déclenché via l'API Immich à la fin de l'archivage pour rafraîchir les vignettes, sans créer de doublons ni perdre de métadonnées.

## Logs

```
/var/log/immich-auto-dumper/immich-auto-dumper.log   # opérations
/var/log/immich-auto-dumper/cron.log                 # sortie cron
```
