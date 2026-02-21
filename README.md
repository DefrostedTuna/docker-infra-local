# Docker Infra (Local)

This repository is designed to act as a central set of resources that resemble cloud-based infrastructure for a local development environment. It serves as a starting point that allows developers to create and manage their applications in a way that mimics how they would be run within a true cloud-based production platform.

This approach allows for a local development environment to be self-contained and free from any system-level dependencies that may differ from those available in production. It also ensures that the development process is standardized across platforms, making it easy to deploy and manage applications locally across a variety of different machines. Providing a centralized set of resources in this manner ensures that there are fewer version conflicts between development and production, and streamlines the pipeline for delivering products to end users.

What does this ship with, and how does it work?

- An **Nginx Proxy** with SSL support that routes _actual_ hostnames to the associated application. No more `localhost` nonsense.
- A **MariaDB** database for storing application data.
- A **Redis** cache for speeding up application performance.
- A **Meilisearch** search engine that provides fast, full-text search capabilities.
- A **MinIO** object storage service for storing large files with an S3-compatible API.

All of these are tied together using both Docker, and an associated Docker Network.

The Nginx Proxy is, well, a reverse proxy. Its role is to act as a load balancer within the ecosystem. It is responsible for routing all inbound traffic on the local machine to the associated service using a `VIRTUAL_HOST` variable set on each downstream service. It supports HTTPS with SSL, and even generates SSL certificates automatically with the bundled Certificate Helper container.

The rest of the services in this stack are commonly used in cloud environments by web applications. These are used to host data persistence across applications, as well as provide tooling that is widely available among providers.

Additional services can be added depending on the use case, and multiple versions of the same service can run alongside each other if requirements differ from project to project.

## Table of Contents

- [Getting Started](#getting-started)
- [Resources](#resources)
  - [Reverse Proxy](#reverse-proxy)
    - [Virtual Hosts and DNS Resolution](#virtual-hosts-and-dns-resolution)
    - [HTTPS and SSL Termination](#https-and-ssl-termination)
  - [Certificate Helper](#certificate-helper)
  - [Whoami](#whoami)
  - [MariaDB](#mariadb)
  - [Redis](#redis)
  - [Meilisearch](#meilisearch)
  - [MinIO](#minio)
  - [MinIO Bucket Helper](#minio-bucket-helper)
- [Application Integration](#application-integration)
  - [Network Configuration](#network-configuration)
  - [Service Discovery](#service-discovery)
  - [Virtual Hosts](#virtual-hosts)
  - [SSL Certificate Support](#ssl-certificate-support)
  - [Complete Example](#complete-example)
- [Wrapping Up](#wrapping-up)

## Getting Started

To get started with this stack, the only real dependency needed is [Docker](https://www.docker.com/).

Once Docker is available, pull a copy of this repository down to your local machine.

```conf
git clone git@github.com:DefrostedTuna/docker-infra-local.git && cd docker-infra-local
```

The next step is to simply spin the containers up using `docker compose`.

```conf
# In the foreground...
docker-compose up

# Or in the background...
docker-compose up -d
```

That's it. Once the containers are spun up, a cloud-style set of resources will be available to any application connected to the same Docker network.

To stop the containers, use the following command.

```conf
docker compose down
```

This will stop and remove all containers, but will preserve any data that has been persisted to the local filesystem. To also remove the persisted _volume_ data, add the `-v` flag. Filesystem data will still remain.

```conf
docker compose down -v
```

## Resources

The resources in this stack operate both individually as isolated services, and together as a unified whole. They are sandboxed so that they do not interfere with one another, but also connected so that they can be accessed by any other container on the same Docker network.

The reverse proxy handles all inbound traffic and routes requests to the appropriate container based on hostname. The remaining services provide persistent storage, caching, search capabilities, and object storage that can be shared across multiple applications.

The default network used throughout the stack is named `local`. This network name may be changed, and additional networks may be added as desired. Any container that shares the same network as another can reference the containers on the network by _container name_ in place of an IP address.

The following services are available out of the box:

| Service Name        | Container Name      | Hostname          | Ports      |
| ------------------- | ------------------- | ----------------- | ---------- |
| reverse-proxy       | reverse-proxy       | ---               | 80, 443    |
| cert-helper         | cert-helper         | ---               | ---        |
| whoami              | whoami              | whoami.local      | ---        |
| mariadb             | mariadb             | mariadb.local     | 3306       |
| redis               | redis               | redis.local       | 6379       |
| meilisearch         | meilisearch         | meilisearch.local | 7700       |
| minio               | minio               | minio.local       | 9000, 9001 |
| minio-bucket-helper | minio-bucket-helper | ---               | ---        |

In order to assign a container to the network that is part of a _different_ `docker-compose.yaml` file, the network must be defined as an _external_ network.

```yaml
networks:
  local:
    name: local
    external: true

services:
  awesome_web_api:
    image: example/awesome-web-api
    container_name: awesome-web-api
    networks:
      - local
```

### Reverse Proxy

The reverse proxy is the core component that ties the ecosystem together. It binds to ports `80` and `443` on the local machine and routes inbound traffic to the appropriate services with a matching `VIRTUAL_HOST` environment variable. Each time a container joins the same network as the reverse proxy, the reverse proxy will automatically refresh its configuration and route matching traffic to the associated container.

This setup ensures that all services in the ecosystem are accessible via a dedicated hostname rather than using `localhost` with various port numbers. The proxy also handles SSL termination for HTTPS connections, making it easy to host applications in the same manner that would be found in a production environment.

**Note:** Ports `80` and `443` must be available on the local machine. If another service is already using these ports, the reverse proxy will fail to start.

#### Virtual Hosts and DNS Resolution

In order for the reverse proxy to resolve hostnames correctly, a `VIRTUAL_HOST` value must be bound to both a container on the same network, as well as to `127.0.0.1` within the system's `hosts` file.

Assigning the `VIRTUAL_HOST` variable to a container is as simple as binding it to the container's environment when it is created.

```yaml
# docker-compose.yaml
services:
  whoami:
    image: jwilder/whoami
    container_name: whoami
    environment:
      VIRTUAL_HOST: whoami.local
    networks:
      - local
```

This can also be specified within a `.env` file.

```bash
# .env
VIRTUAL_HOST=whoami.local
```

```yaml
# docker-compose.yaml
services:
  whoami:
    image: jwilder/whoami
    container_name: whoami
    env_file: .env
    networks:
      - local
```

It can even be passed directly as an argument when running a container from the command line.

```
docker run -d \
  --name whoami \
  --network local \
  -e VIRTUAL_HOST=whoami.local \
  jwilder/whoami
```

Binding the hostname to the system's `hosts` file varies depending on the system used.

```conf
# /etc/hosts -- Unix Systems
# C:\Windows\System32\drivers\etc\hosts -- Windows Systems

127.0.0.1    whoami.local
127.0.0.1    mariadb.local
127.0.0.1    redis.local
127.0.0.1    meilisearch.local
127.0.0.1    minio.local
```

#### HTTPS and SSL Termination

The reverse proxy handles SSL termination for all containers in the stack. When an HTTPS request is received, the proxy looks for a certificate file that matches the requested hostname. Certificates are stored in the `config/nginx-proxy/certs/` directory, with the certificate file named `{domain}.crt` and the private key named `{domain}.key`.

The bundled Certificate Helper container automatically generates self-signed certificates for domains listed in `config/cert-helper/domains.conf`. This allows applications to be served over HTTPS without manually creating certificates.

Since the certificates are self-signed, they are not trusted by default by browsers or the operating system. To avoid browser warnings, the certificates must be added to the local system's trust store.

**macOS**

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain config/nginx-proxy/certs/{domain}.crt
```

**Linux (Arch)**

```bash
# Recommended
sudo trust anchor --store config/nginx-proxy/certs/{domain}.crt

# Manually
sudo cp config/nginx-proxy/certs/{domain}.crt /etc/ca-certificates/trust-source/anchors/

sudo update-ca-trust
```

**Linux (Debian/Ubuntu)**

```bash
sudo cp config/nginx-proxy/certs/{domain}.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

**Windows**

```
certutil -addstore -f "ROOT" config\nginx-proxy\certs\{domain}.crt
```

After adding the certificate to the trust store, browsers will validate the certificate without warnings.

**Note:** Most browsers will require a restart for the certificate stores to see the new certificates.

### Certificate Helper

The certificate helper is a companion container that automatically generates self-signed SSL certificates for the reverse proxy. It watches the `config/cert-helper/domains.conf` file and creates certificates for any domain or hostname that does not already have one. Certificates are regenerated automatically when they approach expiration. This allows applications to be served over HTTPS locally, mirroring how they would be configured in a production environment.

The certificate helper service can be configured with the following environment variables:

| Environment Variable     | Default               | Description                                    |
| ------------------------ | --------------------- | ---------------------------------------------- |
| `DOMAINS_FILE`           | `/config/domains.conf` | Path to the domains configuration file         |
| `CHECK_INTERVAL`         | `5s`                  | How often to poll for file changes             |
| `RENEWAL_THRESHOLD_DAYS` | `30`                  | Regenerate certs expiring within {N} days      |
| `CERT_CHECK_INTERVAL`    | `86400s`              | How often to check certificates for expiration |
| `CERT_VALIDITY_DAYS`     | `365`                 | Validity period for new certificates           |
| `CLEANUP_ORPHANED`       | `true`                | Remove certs for domains no longer in config   |

Since the certificates are self-signed, they are not trusted by default by browsers or the operating system. To avoid browser warnings, the certificates must be added to the local system's trust store. See [HTTPS and SSL Termination](#https-and-ssl-termination) for more details.

### Whoami

The whoami container is a simple echo service used to verify that the reverse proxy is functioning correctly. If there are issues connecting to a container via its hostname, the whoami service can be used to confirm that the proxy is routing traffic as expected.

```
curl whoami.local
```

This would output the container's assigned `id`.

```
I'm 29ac0f74b1fb
```

The `whoami.local` hostname must be present in the system's hosts file for this to work.

### MariaDB

The MariaDB service provides a relational database that persists data to the local filesystem. Abstracting the database to a global level allows multiple applications to share the same database instance, reducing resource duplication and providing a single point of management.

By default, no databases are created. A database can be created using the following command.

```conf
docker exec mariadb mysql -u root -psecret -e "CREATE DATABASE database_name;"
```

Permissions must be granted to users after a database is created in this way.

```conf
docker exec mariadb mysql -u root -psecret -e "GRANT ALL PRIVILEGES ON database_name.* TO 'admin'@'%'; FLUSH PRIVILEGES;"
```

External tools such as [Sequel Ace](https://sequel-ace.com/) can connect to the database using the hostname `mariadb.local` and the credentials defined below.

| Key           | Value         |
| ------------- | ------------- |
| Hostname      | mariadb.local |
| Port          | 3306          |
| Root Password | secret        |
| Username      | admin         |
| Password      | secret        |

### Redis

The Redis service provides an in-memory data store that can be used for caching, session management, or queuing. It is intended to be used as an ephemeral caching layer and does not persist data by default. No credentials are required to connect.

| Key      | Value       |
| -------- | ----------- |
| Hostname | redis.local |
| Port     | 6379        |


### Meilisearch

The Meilisearch service provides a fast, full-text search engine. It persists data to the local filesystem and requires a master key for authentication. The search engine can be accessed via the hostname `meilisearch.local` or through the API at port `7700`.

| Key        | Value                   |
| ---------- | ----------------------- |
| Hostname   | meilisearch.local       |
| Port       | 7700                    |
| Master Key | super-secret-master-key |

### MinIO

The MinIO service provides S3-compatible object storage. It exposes both an API endpoint on port `9000` and a web console on port `9001`. The console is available via the reverse proxy at `https://minio.local` without specifying a port.

Data is persisted to the local filesystem, and the MinIO Bucket Helper container can be used to automatically create buckets defined in `config/minio/buckets.conf`.

| Key          | Value       |
| ------------ | ----------- |
| Hostname     | minio.local |
| API Port     | 9000        |
| Console Port | 9001        |
| Username     | minioadmin  |
| Password     | minioadmin  |

### MinIO Bucket Helper

The MinIO Bucket Helper is a companion container that automatically creates buckets on the MinIO instance. Similar to the Certificate Helper, it watches the `config/minio/buckets.conf` file and creates any bucket that does not already exist. It also sets the access policy for each bucket based on the configuration.

Buckets are defined one per line, with an optional access policy. The available access policies are public (full public access), download (public read access), and private (no public access). If no policy is specified, the bucket defaults to private.

The bucket helper service can be configured with the following environment variables:

| Environment Variable  | Default               | Description                            |
| --------------------- | --------------------- | -------------------------------------- |
| `BUCKETS_FILE`        | `/config/buckets.conf` | Path to the buckets configuration file |
| `MINIO_ENDPOINT`      | `http://minio:9000`   | MinIO API endpoint                     |
| `MINIO_ROOT_USER`     | `minioadmin`          | MinIO admin username                   |
| `MINIO_ROOT_PASSWORD` | `minioadmin`          | MinIO admin password                   |
| `CHECK_INTERVAL`      | `5s`                  | How often to poll for file changes     |

## Application Integration

Integrating an application into this ecosystem is straightforward and can be done with minimal effort.

### Network Configuration

Assuming that this infra stack is already up and running, the first step is to ensure that the application is connected to the same Docker network. This can be done either via a `docker-compose.yaml` manifest, or straight from the command line.

```
docker run -d \
  --name awesome-web-api \
  --network local \
  example/awesome-web-api
```

```yaml
# docker-compose.yaml
networks:
  local:
    name: local
    external: true

services:
  awesome_web_api:
    image: example/awesome-web-api
    container_name: awesome-web-api
    networks:
      - local
```

Both of these snippets accomplish the same goal of assigning the `local` network to the container. The key difference is that the first snippet uses the `--network` approach, while the `docker-compose.yaml` manifest must define the network as `external: true` to signify that it should not be _created_, but rather that it is a reference to an existing network.

### Service Discovery

Once the container is connected to the `local` network, it can communicate with any other container on the network using the container name as the hostname. Docker's internal DNS resolves these names automatically, eliminating the need to manage IP addresses.

An application that requires a database connection would use `mariadb` as the database host instead of `localhost`, or an IP address. Similarly, a Redis connection would use `redis` as the host.

```
docker run -d \
  --name awesome-web-api \
  --network local \
  -e DB_HOST=mariadb \
  -e REDIS_HOST=redis \
  example/awesome-web-api
```

```yaml
# docker-compose.yaml
networks:
  local:
    name: local
    external: true

services:
  awesome_web_api:
    image: example/awesome-web-api
    container_name: awesome-web-api
    networks:
      - local
    environment:
      DB_HOST: mariadb
      REDIS_HOST: redis
```

Using hostnames in this way provides stability across container restarts. If a container is recreated and assigned a new IP address, the hostname resolution remains consistent.

### Virtual Hosts

To expose an application via a hostname through the reverse proxy, the `VIRTUAL_HOST` variable must be set on the container. This tells the reverse proxy to route traffic to the associated service using the hostname that was specified.

```
docker run -d \
  --name awesome-web-api \
  --network local \
  -e VIRTUAL_HOST=api.awesome-web.local \
  example/awesome-web-api
```

```yaml
# docker-compose.yaml
networks:
  local:
    name: local
    external: true

services:
  awesome_web_api:
    image: example/awesome-web-api
    container_name: awesome-web-api
    networks:
      - local
    environment:
      VIRTUAL_HOST: api.awesome-web.local
```

For this hostname to resolve correctly, it must be added to the system's `hosts` file and point to `127.0.0.1`.

```conf
# /etc/hosts -- Unix Systems
# C:\Windows\System32\drivers\etc\hosts -- Windows Systems

127.0.0.1    api.awesome-web.local
```

The combination of setting the `VIRTUAL_HOST` variable and adding it to the `hosts` file will expose the application via `http://api.awesome-web.local`.

### SSL Certificate Support

To serve an application over HTTPS, add the hostname to the `config/cert-helper/domains.conf` file. The certificate helper service will automatically generate a self-signed SSL certificate for the hostname when it detects the change.

```conf
# config/cert-helper/domains.conf

api.awesome-web.local
```

Once the certificate is generated, the application will be accessible via `https://api.awesome-web.local`. However, since the certificate is self-signed, browsers will display a warning. To resolve this, add the certificate to the local system's trust store. See the [HTTPS and SSL Termination](#https-and-ssl-termination) section for details.

### Complete Example

Configuring an application to leverage these resources will allow for a more streamlined development experience. Tying all of this together, a basic configuration would look like the following.

```yaml
# docker-compose.yaml
networks:
  local:
    name: local
    external: true

services:
  awesome_web_api:
    image: example/awesome-web-api
    container_name: awesome-web-api
    restart: unless-stopped
    environment:
      VIRTUAL_HOST: api.awesome-web.local
      DB_HOST: mariadb
      DB_PORT: 3306
      DB_DATABASE: awesome_web
      DB_USERNAME: admin
      DB_PASSWORD: secret
      REDIS_HOST: redis
      REDIS_PORT: 6379
      MEILISEARCH_HOST: meilisearch
      MEILISEARCH_KEY: super-secret-master-key
      MINIO_ENDPOINT: http://minio:9000
      MINIO_ACCESS_KEY: minioadmin
      MINIO_SECRET_KEY: minioadmin
    volumes:
      - ./:/path/to/containerized/app
    networks:
      - local
```

Or if a `docker run` command is preferred.

```
docker run -d \
  --name awesome-web-api \
  --restart unless-stopped \
  --network local \
  -e VIRTUAL_HOST=api.awesome-web.local \
  -e DB_HOST=mariadb \
  -e DB_PORT=3306 \
  -e DB_DATABASE=awesome_web \
  -e DB_USERNAME=admin \
  -e DB_PASSWORD=secret \
  -e REDIS_HOST=redis \
  -e REDIS_PORT=6379 \
  -e MEILISEARCH_HOST=meilisearch \
  -e MEILISEARCH_KEY=super-secret-master-key \
  -e MINIO_ENDPOINT=http://minio:9000 \
  -e MINIO_ACCESS_KEY=minioadmin \
  -e MINIO_SECRET_KEY=minioadmin \
  -v ./:/path/to/containerized/app \
  example/awesome-web-api
```

Before starting the application, ensure that any service-specific configurations have been made. See the [MariaDB](#mariadb) section for details on creating databases. If the application requires MinIO buckets, they can be defined in the bucket helper configuration. See the [MinIO Bucket Helper](#minio-bucket-helper) section for details.

For more details on configuring each service in depth, refer to the individual service documentation in the [Resources](#resources) section, or consult their official documentation for the desired service.

After the services have been configured to represent the desired state, the application can be spun up with either `docker compose up`, or by running the `docker run` command above.

## Wrapping Up

By centralizing common services and leveraging them in this way, applications can be developed in isolation while still having access to the resources they need. This, alongside being able to host applications from behind a proper hostname complete with HTTPS, allows for a development environment to resemble a production pipeline as closely as possible. All while staying platform-agnostic at the same time.