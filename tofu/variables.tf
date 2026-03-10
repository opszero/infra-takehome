variable "k3d_cluster_name" {
  description = "Name of the k3d cluster"
  type        = string
  default     = "infra-takehome"
}

variable "k3s_version" {
  description = "K3s image tag to use for cluster nodes"
  type        = string
  default     = "v1.35.2-k3s1"
}

variable "postgres_password" {
  description = "Password for the PostgreSQL postgres superuser"
  type        = string
  default     = "postgres"
  sensitive   = true
}

variable "postgres_port" {
  description = "Host port to expose PostgreSQL on"
  type        = number
  default     = 5435
}

variable "postgrest_db_user" {
  description = "Superuser role created in the postgrest database for PostgREST"
  type        = string
  default     = "postgrest_user"
}

variable "postgrest_db_password" {
  description = "Password for the postgrest superuser role"
  type        = string
  default     = "postgrest_password"
  sensitive   = true
}
