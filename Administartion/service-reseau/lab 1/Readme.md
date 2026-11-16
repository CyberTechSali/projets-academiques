# Lab 1 : Service DNS (BIND9) sur Debian 13

Script interactif qui installe et configure un serveur DNS **BIND9** avec une **zone directe** (nom → IP) et une **zone inverse** (IP → nom), puis vérifie automatiquement que tout fonctionne.

- Domaine du labo : `ingSALI-infra.lan` (modifiable à la première question du script)
- Système : Debian 13, `systemd-networkd`
- Fichier du script : [`config-dns.sh`](config-dns.sh)

## Architecture du labo

```
                         Internet (NAT VMware)
                                  |
                           ens33 | 192.168.100.100
                     +------------+------------+
                     |   Serveur Master (DNS,  |
                     |   DHCP, routeur, NAT)   |
                     +--+---------+---------+--+
                 ens34  |   ens35 |   ens36 |
             10.10.10.254  20.20.20.254  30.30.30.254
                        |         |         |
                   Switch LAN1  Switch LAN2  Switch LAN3
                        |         |         |
                 Client Windows  Client Linux  Client IoT (Linux)
                   (DHCP)          (DHCP)         (DHCP)
```

| Réseau | Sous-réseau | Adresse du Master | Client |
|---|---|---|---|
| NAT / Internet | 192.168.100.0/24 | 192.168.100.100 | (SSH d'administration) |
| LAN 1 | 10.10.10.0/24 | 10.10.10.254 | Windows |
| LAN 2 | 20.20.20.0/24 | 20.20.20.254 | Linux |
| LAN 3 | 30.30.30.0/24 | 30.30.30.254 | IoT (Linux) |

Les noms d'interfaces (`ens33`, `ens34`…) peuvent varier selon la VM. Vérifiez-les avec `ip -br a`.

## Prérequis

- Debian 13 avec accès **root**
- Une adresse IP **fixe** sur le serveur
- Un accès Internet (pour installer les paquets)
- Le serveur doit déjà router les LAN et faire le NAT si les clients doivent sortir sur Internet

## Utilisation

```bash
sudo -i
chmod +x config-dns.sh
./config-dns.sh
```

Le script pose les questions une par une, avec une valeur par défaut entre crochets (Entrée pour la garder), et propose un **mode pas-à-pas** avec une pause après chaque étape.

## Ce que fait le script

| Étape | Action |
|---|---|
| 1 | Questions : domaine, nom du serveur DNS, IP du serveur, forwarder, Slave (option) |
| 2 | Installation de `bind9`, `bind9-utils`, `bind9-dnsutils` |
| 3 | Sauvegarde des fichiers de configuration dans `/root/backup-dns-HHMMSS` |
| 4 | Options globales de BIND (écoute, récursion pour les réseaux connectés, forwarder) |
| 5 | Déclaration des deux zones dans `named.conf.local` |
| 6 | Création des fichiers de zone (SOA, NS, A, CNAME, PTR) |
| 7 | Vérification de la syntaxe (`named-checkconf`, `named-checkzone`) avec restauration en cas d'erreur |
| 8 | Activation et démarrage du service `named` |
| 9 | (Option) Le DHCP distribue le domaine et le DNS aux clients |
| 10 | **Vérification automatique** de la configuration |
| 11 | Affichage des commandes de test à lancer depuis les clients |

Le script peut être relancé sans danger : il réécrit les fichiers et sauvegarde avant de modifier.

## Enregistrements créés

Zone directe `ingSALI-infra.lan` :

| Nom | Type | Valeur |
|---|---|---|
| `@` | NS | `ns.ingSALI-infra.lan.` |
| `@` | A | IP du serveur |
| `ns` | A | IP du serveur |
| `www` | A | IP du serveur |
| `mail` | CNAME | `www` |

Zone inverse `100.168.192.in-addr.arpa` : un enregistrement PTR de l'IP du serveur vers `ns.ingSALI-infra.lan.`.

## Vérifications effectuées par le script

- Le service `named` est actif, activé au démarrage et écoute sur le port 53 (UDP et TCP)
- `named-checkconf` et `named-checkzone` valident la configuration et les deux zones
- Les fichiers de zone sont lisibles par l'utilisateur `bind`
- Le serveur répond avec le drapeau **`aa`** (réponse autoritaire)
- Résolution directe : `ns`, `www`, la racine du domaine, `mail` (CNAME)
- Résolution inverse (PTR)
- Un nom inexistant renvoie bien `NXDOMAIN`
- La résolution d'Internet fonctionne via le forwarder
- Le serveur répond sur chacune de ses adresses (NAT et LAN)

Chaque test affiche `[ OK ]` ou `[ KO ]` avec un conseil de correction, puis un bilan final.

## Tests depuis les clients

**Linux**

```bash
resolvectl status
dig www.ingSALI-infra.lan +short
dig -x 192.168.100.100 +short
ping -c 2 www.ingSALI-infra.lan
```

**Windows (invite de commandes)**

```
ipconfig /release
ipconfig /renew
ipconfig /flushdns
ipconfig /all
nslookup www.ingSALI-infra.lan
nslookup 192.168.100.100
ping www.ingSALI-infra.lan
```

Le DNS affiché doit être celui du Master sur le LAN du client (par exemple `10.10.10.254`).

## Notions à retenir

- **Zone directe / inverse** : la zone inverse s'appelle `100.168.192.in-addr.arpa` pour le réseau `192.168.100.0/24` (trois premiers octets écrits à l'envers).
- **Point final** : dans un fichier de zone, un nom complet se termine par un point (`ns.ingSALI-infra.lan.`). Sans ce point, BIND ajoute le domaine une seconde fois.
- **Numéro de série (SOA)** : il doit augmenter à chaque modification pour qu'un serveur secondaire recopie la zone.
- **Réponse autoritaire** : le drapeau `aa` prouve que le serveur détient la zone, par opposition à une réponse « non-authoritative » issue d'un cache.
- **Forwarder** : les noms que le serveur ne gère pas (Internet) sont envoyés au DNS du NAT VMware.
- **Service** : sous Debian 13 le service s'appelle `named` (`bind9` n'est qu'un alias).

## Problèmes rencontrés et solutions

| Problème | Cause | Solution |
|---|---|---|
| `nslookup` Windows donnait des adresses publiques pour le domaine | Le client utilisait le DNS du NAT (`192.168.100.2`) au lieu du Master | Faire distribuer le DNS du Master par le DHCP, désactiver la carte NAT du client Windows |
| Deux passerelles par défaut sur le client Windows | Cartes NAT et LAN actives en même temps | Désactiver la carte NAT ou lui donner une métrique élevée |
| Carte NAT du client Linux avec une adresse du LAN | Ancienne configuration réseau restée dans le clone | Supprimer les anciens fichiers `.network` et recréer la configuration |
| Carte NAT « DOWN » sur un clone | Aucun fichier `.network` pour cette interface | Créer le fichier correspondant puis `networkctl reconfigure` |
| `ping www.deb.debian.org` échouait | Ce nom n'existe pas (le bon est `deb.debian.org`) | Utiliser le bon nom |
| `nslookup` affichait `Server: UnKnown` | Pas de zone inverse pour l'adresse du serveur DNS | Sans gravité (ou ajouter une zone inverse pour les LAN) |

## Structure du dépôt

```
Administration/
└── service-reseau/
    └── lab-1/
        ├── config-dns.sh     # script de configuration et de vérification
        └── README.md         # ce fichier
```

## Auteur

Projet réalisé dans le cadre du module **Administration des services réseaux**.
