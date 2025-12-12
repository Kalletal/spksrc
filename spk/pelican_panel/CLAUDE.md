# Pelican Panel SPK - Development Guidelines (spksrc format)

## IMPORTANT: spksrc Framework Compliance

Ce paquet DOIT suivre le format spksrc de SynoCommunity. Toute modification doit respecter ces conventions.

## Structure du Paquet

```
spk/pelican_panel/
├── Makefile                    # Configuration principale spksrc
├── CLAUDE.md                   # Ce fichier
├── scripts/
│   └── bump-revision.sh        # Auto-incrémentation de version
└── src/
    ├── PACKAGE_ICON.PNG        # Icône du paquet (256x256)
    ├── service-setup.sh        # Hooks d'installation spksrc
    ├── dsm-control.sh          # Script start/stop/status
    ├── panel.env.example       # Template de configuration
    ├── wings.config.example.yml
    ├── wings-config-watcher.sh
    ├── loading.html
    ├── app/                    # Interface DSM
    │   ├── config              # Configuration DSM UI
    │   ├── *.js                # Scripts JavaScript
    │   └── images/             # Icônes d'application
    ├── bin/
    │   ├── loading-proxy.py    # Proxy de chargement
    │   └── fix-iframe-headers.sh  # Configuration X-Frame-Options
    ├── conf/
    │   ├── privilege           # Privilèges DSM
    │   └── resource            # Ressources DSM
    ├── docker/
    │   └── compose.yaml        # Docker Compose
    ├── patches/                # Patches PHP pour Panel
    │   ├── Node.php
    │   ├── CreateNode.php
    │   └── EditNode.php
    └── wizard/
        ├── install_uifile      # Wizard d'installation
        └── uninstall_uifile    # Wizard de désinstallation
```

## Convention de Nommage

**IMPORTANT**: Le nom du paquet est `pelican_panel` (avec tiret).

- Nom du paquet: `pelican_panel`
- Conteneurs Docker: `pelican_panel-panel-1`, `pelican_panel-wings-1`
- Chemins: `/var/packages/pelican_panel/...`
- Réseau Docker: `pelican_network`

**NE PAS utiliser `pelican_panel` (avec underscore)** sauf pour le réseau Docker.

## Commandes de Build

```bash
# Build standard (depuis spksrc-framework/)
cd spk/pelican_panel
make noarch-7.0

# Build avec auto-incrémentation de version
make bump

# Incrémenter la version sans build
make bump-only

# Nettoyer
make clean
```

## Variables Makefile Importantes

| Variable | Description |
|----------|-------------|
| `SPK_NAME` | Nom du paquet (pelican_panel) |
| `SPK_VERS` | Version majeure (1.0.0) |
| `SPK_REV` | Révision (incrémentée automatiquement) |
| `ADMIN_PORT` | Port pour le bouton "Ouvrir" (8080) |
| `SERVICE_PORT` | Port du service principal |
| `CONF_DIR` | Répertoire de configuration (src/conf/) |
| `WIZARDS_DIR` | Répertoire des wizards (src/wizard/) |

## Fichier INFO généré

Le fichier INFO est généré automatiquement par spksrc avec:
- `dsmappname`: Identifiant de l'application DSM
- `adminport`: Port pour le bouton "Ouvrir"
- `dsmuidir`: Répertoire de l'interface DSM (app)

## Service Setup (service-setup.sh)

Fonctions appelées par spksrc:
- `service_preinst()`: Avant installation
- `service_postinst()`: Après installation
- `service_preupgrade()`: Avant mise à jour
- `service_postupgrade()`: Après mise à jour
- `service_preuninst()`: Avant désinstallation
- `service_postuninst()`: Après désinstallation

## DSM Control (dsm-control.sh)

Script start/stop/status avec les commandes:
- `start`: Démarrer les conteneurs Docker
- `stop`: Arrêter les conteneurs Docker
- `status`: Vérifier l'état (exit 0 = running, exit 1 = stopped)

## Fichier app/config (DSM UI)

Le fichier `src/app/config` définit les applications DSM disponibles dans le paquet.

### Types d'applications

1. **`.url`** - Ouvre une URL dans un nouvel onglet navigateur
   - Actuellement utilisé pour le bouton "Ouvrir" du Centre de Paquets
   - Pas d'intégration iframe dans DSM

2. **`app`** - Application ExtJS intégrée dans DSM
   - Permet l'affichage dans une fenêtre DSM avec iframe
   - Requiert un fichier `.js` associé (ex: `PelicanPanel.js`)

### Configuration pour iframe DSM (Feature 001)

Pour intégrer le panel dans une frame DSM, utiliser le type `app` :

```json
{
    "PelicanPanel.js": {
        "PelicanPanel.AppInstance": {
            "type": "app",
            "title": "Pelican Panel",
            "icon": "images/pelican_panel-{0}.png",
            "allowMultiInstance": false,
            "allUsers": true,
            "appWindow": "PelicanPanel.AppWindow",
            "depend": ["PelicanPanel.AppWindow"]
        }
    }
}
```

### Intégration iframe DSM - RECHERCHE EN COURS

**Problème** : Le message "Ce contenu est bloqué" apparaît car DSM 7.2+ bloque les iframes vers des URLs externes (ports différents = cross-origin).

**Serveur web Pelican** : Caddy (pas nginx)
- Config : `/etc/caddy/Caddyfile` dans le container
- Par défaut, aucun header X-Frame-Options n'est défini

**Recherche complète** : Voir `research.md`

### Solutions possibles

1. **Reverse Proxy DSM** (via nginx)
   - Installer config dans `/etc/nginx/conf.d/www.pelican_panel.conf`
   - L'iframe charge `/webman/3rdparty/pelican_panel/panel/` (same-origin)
   - **Statut** : Testé mais problème de routage Pelican (liens absolus)

2. **type: url** (nouvel onglet)
   - Comme Jellyfin, Nextcloud
   - Simple et fiable, mais pas intégré dans DSM

3. **CGI Proxy Script**
   - Script PHP/CGI dans `app/` qui proxy vers localhost:8090
   - Complexe mais same-origin

### Ressources DSM Developer

- [DSM Developer Guide 7](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf)
- [HowTo: iFrame DSM 7.2+](https://www.synology-forum.de/threads/howto-iframe-oeffne-dich-app-integration-ab-dsm-7-2.127186/)
- [spksrc Issue #5544](https://github.com/SynoCommunity/spksrc/issues/5544)
- [SimpleExtJSApp](https://github.com/DigitalBox98/SimpleExtJSApp)

### Pattern ExtJS pour iframe

```javascript
Ext.define("PelicanPanel.AppWindow", {
    extend: "SYNO.SDS.AppWindow",
    constructor: function(config) {
        // L'URL doit être same-origin (chemin relatif DSM)
        // PAS: 'http://host:8090/' (bloqué)
        // OUI: '/webman/3rdparty/pelican_panel/panel/' (si proxy configuré)
    }
});
```

## Docker Compose

Les noms de conteneurs doivent correspondre au format `${PACKAGE}-service-1`:
- `pelican_panel-panel-1`
- `pelican_panel-wings-1`

## Patches PHP

Les patches sont montés en volume read-only dans le conteneur Panel. Ils écrasent les fichiers originaux de l'image Docker.

### Liste des patches

| Fichier | Chemin dans conteneur | Description |
|---------|----------------------|-------------|
| `Node.php` | `/var/www/html/app/Models/Node.php` | Port Wings par défaut 8445 |
| `CreateNode.php` | `/var/www/html/app/Filament/Admin/Resources/Nodes/Pages/CreateNode.php` | Port Wings par défaut 8445 |
| `EditNode.php` | `/var/www/html/app/Filament/Admin/Resources/Nodes/Pages/EditNode.php` | Port Wings par défaut 8445 |
| `EnvironmentStep.php` | `/var/www/html/app/Livewire/Installer/Steps/EnvironmentStep.php` | Fix APP_URL dans wizard |

### EnvironmentStep.php - Fix APP_URL

**Problème** : Dans le wizard d'installation, le champ APP_URL affiche `http://127.0.0.1:8080` (URL interne du conteneur) au lieu de l'URL réelle du navigateur.

**Cause** : Laravel `url('')` détecte l'URL depuis la requête HTTP. Dans un conteneur Docker derrière un proxy, sans `TRUSTED_PROXIES` correctement configuré au moment de l'installation, Laravel détecte l'IP interne.

**Solution** : Injection JavaScript via Alpine.js pour corriger l'URL côté client.

**Code ajouté** (ligne 27) :
```php
->extraInputAttributes([
    'x-init' => "\$nextTick(() => { if (\$el.value.includes('127.0.0.1') || \$el.value.includes('localhost')) { \$el.value = window.location.origin; \$wire.set('data.env_general.APP_URL', window.location.origin); } })"
])
```

**Comportement** :
1. Attend l'initialisation du composant (`$nextTick`)
2. Vérifie si l'URL contient `127.0.0.1` ou `localhost`
3. Remplace par `window.location.origin` (URL réelle du navigateur)
4. Met à jour l'état Livewire avec `$wire.set()`

**Version Pelican testée** : latest (décembre 2024)

**En cas d'incompatibilité future** :
1. Récupérer le fichier original : `docker run --rm ghcr.io/pelican-dev/panel:latest cat /var/www/html/app/Livewire/Installer/Steps/EnvironmentStep.php`
2. Comparer avec notre patch
3. Réappliquer la modification `extraInputAttributes` sur le champ `env_general.APP_URL`

## Loading Proxy - Migrations automatiques

Le fichier `src/bin/loading-proxy.py` sert une page de chargement pendant l'initialisation du Panel et exécute automatiquement les migrations si les tables sont manquantes.

### Fonctionnalités

1. **Détection des tables manquantes** : Vérifie si la base SQLite contient les tables via `artisan tinker`
2. **Exécution des migrations** : Lance `php artisan migrate --force` si nécessaire
3. **Affichage en temps réel** : Capture et affiche chaque migration dans l'interface
4. **Flag de completion** : Crée `$VAR_DIR/migrations_complete` pour éviter les re-exécutions

### Flux d'initialisation

```
1. Container Docker démarre
2. loading-proxy.py détecte le container
3. Vérifie si les tables existent (artisan tinker)
4. Si tables manquantes → exécute migrations avec sortie temps réel
5. Page loading.html affiche la progression (Tables: X/222)
6. Migrations terminées → vérification santé panel
7. Panel prêt → affiche page d'instructions
8. Validation instructions → wizard Pelican démarre
```

### Fichiers de flag

| Fichier | Description |
|---------|-------------|
| `$VAR_DIR/migrations_complete` | Migrations exécutées avec succès |
| `$VAR_DIR/install_complete` | Instructions affichées à l'utilisateur |

### Debug

Logs visibles dans le terminal loading-proxy :
```
[proxy] Waiting for container to be ready...
[proxy] Container is ready
[proxy] Tables don't exist - migrations needed
[proxy] Starting database migrations...
[migration] 2016_01_23_195641_add_allocations_table ... DONE
...
[proxy] Migrations completed successfully (222 tables)
```

## Ressources

- [spksrc Wiki](https://github.com/SynoCommunity/spksrc/wiki)
- [Developers HOW-TO](https://github.com/SynoCommunity/spksrc/wiki/Developers-HOW-TO)
- [CONTRIBUTING.md](https://github.com/SynoCommunity/spksrc/blob/master/CONTRIBUTING.md)
