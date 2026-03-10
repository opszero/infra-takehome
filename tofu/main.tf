provider "docker" {}

resource "docker_network" "infra" {
  name = "infra-takehome-network"
}

resource "terraform_data" "k3d_cluster" {
  input = {
    name    = var.k3d_cluster_name
    image   = "rancher/k3s:${var.k3s_version}"
    network = docker_network.infra.name
  }

  provisioner "local-exec" {
    command = "k3d cluster create ${self.input.name} --image ${self.input.image} --servers 1 --agents 0 -p '8080:80@loadbalancer' --network ${self.input.network}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.input.name}"
  }
}

resource "docker_image" "postgres" {
  name         = "postgres:16-alpine"
  keep_locally = true
}

resource "docker_container" "postgres" {
  name  = "postgres-infra-takehome"
  image = docker_image.postgres.image_id

  env = [
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=app",
  ]

  ports {
    internal = 5432
    external = var.postgres_port
  }

  networks_advanced {
    name    = docker_network.infra.name
    aliases = ["postgres"]
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  restart = "unless-stopped"
}

resource "docker_volume" "postgres_data" {
  name = "postgres-infra-takehome-data"
}

provider "postgresql" {
  host     = "localhost"
  port     = var.postgres_port
  username = "postgres"
  password = var.postgres_password
  sslmode  = "disable"
}

resource "terraform_data" "wait_for_postgres" {
  depends_on = [docker_container.postgres]

  provisioner "local-exec" {
    command = "until pg_isready -h localhost -p ${var.postgres_port} -U postgres; do sleep 2; done"
  }
}

resource "postgresql_database" "postgrest" {
  name       = "postgrest"
  depends_on = [terraform_data.wait_for_postgres]
}

resource "postgresql_role" "postgrest_superuser" {
  name      = var.postgrest_db_user
  login     = true
  superuser = true
  password  = var.postgrest_db_password

  depends_on = [postgresql_database.postgrest]
}

# Resolve the postgres container's IP on the shared infra network so that
# Kubernetes pods (routed via the k3d node) can reach it.
locals {
  postgres_ip = [
    for net in docker_container.postgres.network_data :
    net.ip_address
    if net.network_name == docker_network.infra.name
  ][0]
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "k3d-${var.k3d_cluster_name}"
}

resource "kubernetes_namespace" "postgrest" {
  metadata {
    name = "postgrest"
  }
  depends_on = [terraform_data.k3d_cluster]
}

# Secret consumed by the PostgREST deployment and the seed Job.
resource "kubernetes_secret" "postgrest" {
  metadata {
    name      = "postgrest-config"
    namespace = kubernetes_namespace.postgrest.metadata[0].name
  }

  data = {
    PGRST_DB_URI       = "postgres://${var.postgrest_db_user}:${var.postgrest_db_password}@postgres.postgrest.svc.cluster.local:5432/postgrest"
    PGRST_DB_SCHEMA    = "public"
    PGRST_DB_ANON_ROLE = var.postgrest_db_user
    PGRST_SERVER_PORT  = "3000"
  }

  depends_on = [postgresql_role.postgrest_superuser]
}

# Manual Endpoints object pointing to the postgres container's Docker IP.
# Paired with the headless Service below so that pods resolve "postgres:5432"
# via CoreDNS → Kubernetes Service → this Endpoints entry.
resource "kubernetes_endpoints_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.postgrest.metadata[0].name
  }

  subset {
    address {
      ip = local.postgres_ip
    }
    port {
      port     = 5432
      protocol = "TCP"
    }
  }
}

# Selector-less Service — backends are provided by kubernetes_endpoints_v1 above.
resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace.postgrest.metadata[0].name
  }

  spec {
    port {
      port        = 5432
      target_port = "5432"
      protocol    = "TCP"
    }
  }
}
