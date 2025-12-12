# Recherche : Intégration iframe DSM pour Pelican Panel

## Problème

Le message "Ce contenu est bloqué. Pour résoudre le problème, contactez le propriétaire du site." apparaît lors de l'affichage de Pelican Panel dans une iframe DSM.

## Cause identifiée

DSM 7.2+ bloque les iframes vers des URLs externes (ports différents, cross-origin).
L'iframe doit pointer vers un chemin **local DSM** (`webman/3rdparty/...`), pas vers un port externe.

## Solutions recherchées

### 1. Pattern DSM 7.2+ (Forum Allemand)

Source: [synology-forum.de - HowTo: iFrame öffne dich!](https://www.synology-forum.de/threads/howto-iframe-oeffne-dich-app-integration-ab-dsm-7-2.127186/)

**Principe** : L'iframe charge un fichier local dans `webman/3rdparty/[APP]/`

```javascript
getMainHtml: function(){
    return '<iframe src="webman/3rdparty/[APPLICATION_NAME]/index.html?'
        + new Date().getTime()
        + '" style="width: 100%; height: 100%; border: none;"/>';
}
```

**Limitation** : Fonctionne pour les apps dont le contenu est servi depuis le répertoire du package, pas pour les apps Docker sur port externe.

### 2. Reverse Proxy via spksrc

Source: [spksrc Issue #5544](https://github.com/SynoCommunity/spksrc/issues/5544)

**Statut** : Non fonctionnel programmatiquement. La configuration automatique via package manifest ne fonctionne pas.

Configuration manuelle via DSM UI fonctionne:
- Panneau de configuration → Portail de connexion → Avancé → Proxy inversé

### 3. Configuration nginx manuelle

Source: [SynoForum - Reverse Proxy under the hood](https://www.synoforum.com/resources/synology-reverse-proxy-under-the-hood.135/)

Fichiers concernés:
- `/etc/nginx/sites-enabled/server.ReverseProxy.conf`
- `/etc/nginx/conf.d/www.*.conf` (pour locations dans server existant)
- `/usr/syno/etc/www/ReverseProxy.json`

### 4. Paramètre de sécurité DSM

Source: [Synology SSO Server Specs](https://www.synology.com/en-us/dsm/7.1/software_spec/sso_server)

- Panneau de configuration → Sécurité → "Ne pas autoriser l'intégration de DSM dans un iFrame"
- Ce paramètre concerne l'embedding de DSM lui-même, pas les apps tierces

## Approches possibles pour Pelican Panel

### A. CGI Proxy Script

Créer un script CGI/PHP dans `app/` qui agit comme proxy vers localhost:8090.
L'iframe charge ce script local.

**Avantages** : Same-origin, pas de blocage
**Inconvénients** : Complexe, performances, maintien des sessions

### B. Reverse Proxy manuel

Configurer manuellement le reverse proxy DSM via l'interface.
L'utilisateur doit le faire post-installation.

**Configuration suggérée** :
- Source: `/pelican` ou `/webman/3rdparty/pelican_panel/panel`
- Destination: `http://localhost:8090`

### C. type: url (Nouvel onglet)

Abandonner l'iframe et utiliser `type: url` comme Jellyfin, Nextcloud.
Ouvre Pelican dans un nouvel onglet du navigateur.

**Avantages** : Simple, fiable
**Inconvénients** : Pas intégré dans DSM

### D. Nginx location via script

Installer la config nginx dans `/etc/nginx/conf.d/www.pelican_panel.conf` via le script start.
Nécessite test et reload nginx.

**Note** : Testé mais le fichier n'était pas créé - à investiguer.

## Solution implémentée (v28) : CGI/PHP Proxy

### Fichiers créés

1. **`src/app/router.cgi`** - Script bash qui exécute PHP via php-cgi
2. **`src/app/proxy.php`** - Script PHP qui proxy vers localhost:8090

### Fonctionnement

```
DSM iframe
   └─> /webman/3rdparty/pelican_panel/router.cgi?p=/
           └─> router.cgi exécute proxy.php
                   └─> proxy.php fetch http://127.0.0.1:8090/
                           └─> Retourne le contenu avec X-Frame-Options: SAMEORIGIN
```

### Code clé (proxy.php)

```php
// Supprime les headers bloquants
header('X-Frame-Options: SAMEORIGIN');
// Proxy vers Pelican
$target_url = "http://127.0.0.1:8090" . $path;
$result = fetch_content($target_url);
// Réécrit les URLs pour passer par le proxy
$content = rewrite_urls($result['body'], $proxy_base);
```

### Prérequis DSM

- PHP doit être installé (Web Station ou php-cgi disponible)
- Le script CGI doit être exécutable

## Conclusion actuelle

Solution CGI/PHP proxy implémentée dans v28. Si ça ne fonctionne pas, fallback sur **type: url** (nouvel onglet).

## Références

- [DSM Developer Guide 7](https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf)
- [spksrc GitHub](https://github.com/SynoCommunity/spksrc)
- [DigitalBox98/SimpleExtJSApp](https://github.com/DigitalBox98/SimpleExtJSApp)
- [SynoForum - DSM UI framework](https://www.synoforum.com/threads/dsm-ui-framework.7779/)
