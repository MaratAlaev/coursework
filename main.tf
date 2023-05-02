terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  cloud_id  = "b1g5uqdv6c1ofocq53vq"
  folder_id = "b1gamifnjr6h49otdp48"
}

resource "yandex_compute_instance" "vm-1" {

  name        = "vm-bastion"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8i3uauimpm750kd9vh"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-1.id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  provisioner "remote-exec" {
    inline = [
      "echo OK"
    ]
  }

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = yandex_compute_instance.vm-1.network_interface.0.nat_ip_address
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "local-exec" {
    command = "scp ~/.ssh/id_rsa ubuntu@${yandex_compute_instance.vm-1.network_interface.0.nat_ip_address}:/home/ubuntu/.ssh/id_rsa"
  }

  provisioner "local-exec" {
    command = "scp grafana-enterprise_9.4.7_amd64.deb ubuntu@${yandex_compute_instance.vm-1.network_interface.0.nat_ip_address}:/home/ubuntu/"
  }

  provisioner "local-exec" {
    command = "scp dashboard.json ubuntu@${yandex_compute_instance.vm-1.network_interface.0.nat_ip_address}:/home/ubuntu/"
  }

  provisioner "local-exec" {
    command = "scp nginx.conf ubuntu@${yandex_compute_instance.vm-1.network_interface.0.nat_ip_address}:/home/ubuntu/"
  }

  provisioner "local-exec" {
    command = "scp filebeat-8.7.0-amd64.deb ubuntu@${yandex_compute_instance.vm-1.network_interface.0.nat_ip_address}:/home/ubuntu/"
  }

  provisioner "local-exec" {
    command = "scp kibana-8.7.0-amd64.deb ubuntu@${yandex_compute_instance.vm-1.network_interface.0.nat_ip_address}:/home/ubuntu/"
  }


  provisioner "file" {
    content     = <<EOT
    [webservers]
    ${yandex_compute_instance_group.ig-1.instances.0.network_interface.0.ip_address}      ansible_ssh_extra_args='-o StrictHostKeyChecking=no'
    ${yandex_compute_instance_group.ig-1.instances.1.network_interface.0.ip_address}      ansible_ssh_extra_args='-o StrictHostKeyChecking=no'
    
    [prometheus]
    ${yandex_compute_instance.vm-2.network_interface.0.ip_address}                        ansible_ssh_extra_args='-o StrictHostKeyChecking=no'

    [grafana]
    ${yandex_compute_instance.vm-3.network_interface.0.ip_address}                        ansible_ssh_extra_args='-o StrictHostKeyChecking=no'

    [elasticsearch]
    ${yandex_compute_instance.vm-4.network_interface.0.ip_address}                        ansible_ssh_extra_args='-o StrictHostKeyChecking=no'

    [kibana]
    ${yandex_compute_instance.vm-5.network_interface.0.ip_address}                        ansible_ssh_extra_args='-o StrictHostKeyChecking=no'
    EOT
    destination = "./host"
  }

  provisioner "file" {
    content = <<EOT
- hosts: webservers
  remote_user: ubuntu
  become: yes
  become_method: sudo

  tasks:
   - name: Ansible apt install nginx
     apt:
      name: nginx
      state: present

   - name: edit nginx file
     copy:
      src: nginx.conf
      dest: /etc/nginx/nginx.conf

   - name: start Node Exporter service
     service: 
      name: nginx 
      state: restarted 
   
   - name:  Permissions file access.log
     file:
      path: /var/log/nginx/access.log
      mode: '0777'
    EOT

    destination = "./nginx-playbook.yml"
  }

  provisioner "file" {
    content = <<EOT
- hosts: webservers
  remote_user: ubuntu
  become: yes
  become_method: sudo

  tasks:
   - name: download node exporter
     get_url:
      url: https://github.com/prometheus/node_exporter/releases/download/v1.5.0/node_exporter-1.5.0.linux-amd64.tar.gz
      dest: ./

   - name: download nginx exporter
     get_url:
      url: https://github.com/martin-helmich/prometheus-nginxlog-exporter/releases/download/v1.9.2/prometheus-nginxlog-exporter_1.9.2_linux_amd64.deb
      dest: ./

   - name: Install nginx exporter
     apt:
      deb: prometheus-nginxlog-exporter_1.9.2_linux_amd64.deb

   - name: Start nginx exporter
     service: 
      name: prometheus-nginxlog-exporter 
      state: started 
      enabled: yes

   - name: Unzip node exporter
     unarchive:
      src: node_exporter-1.5.0.linux-amd64.tar.gz
      dest: ./
      remote_src: true

   - name: Move to bin
     copy:
      src: node_exporter-1.5.0.linux-amd64/node_exporter
      dest: /usr/local/bin/
      mode: '0777'
      remote_src: true

   - name: Node Exporter create service
     template: 
      src:  node_exporter.service  
      dest: /lib/systemd/system/node_exporter.service 
      mode: 644

   - name: start Node Exporter service
     service: 
      name: node_exporter.service 
      state: started 
      enabled: yes
    EOT

    destination = "./nodeinstall-playbook.yml"
  }

  provisioner "file" {
    content = <<EOT
- hosts: webservers
  remote_user: ubuntu
  become: yes
  become_method: sudo

  tasks:
   - name: move filebeat deb
     copy:
      src: filebeat-8.7.0-amd64.deb
      dest: ./

   - name: Install filebeat
     apt:
      deb: filebeat-8.7.0-amd64.deb

   - name: nginx module enable
     shell:
      cmd: sudo filebeat modules enable nginx

   - name: edit filebeat modules
     copy:
      dest: "/etc/filebeat/modules.d/nginx.yml"
      content: |
        - module: nginx
          access:
           enabled: true
           var.paths: ["/var/log/nginx/access.log*", "/var/log/nginx/error.log*"]

   - name: edit nginx edit file
     copy:
      dest: "/etc/filebeat/filebeat.yml"
      content: |    
        filebeat.config.modules:
          path: /etc/filebeat/modules.d/*.yml
          reload.enabled: false


        filebeat.inputs:
        - type: log
          enabled: true
          paths:
            - /var/log/nginx/*.log
          processors:
            - add_host_metadata: ~
            - add_cloud_metadata: ~

        output.elasticsearch:
          hosts: ["${yandex_compute_instance.vm-4.network_interface.0.ip_address}:9200"]

        setup.kibana:
          host: "${yandex_compute_instance.vm-5.network_interface.0.ip_address}:5601"
    
   - name: start Node Exporter service
     service: 
      name: filebeat.service 
      state: restarted  
      enabled: yes

   - name:
     shell: |
      sleep 60
      sudo filebeat setup
    EOT

    destination = "./filebeatinstall-playbook.yml"
  }

  provisioner "file" {
    content = <<EOT
- hosts: elasticsearch
  remote_user: ubuntu
  become: yes
  become_method: sudo

  tasks:
   - name: install 1
     shell: |
      sudo apt-get update

      sudo apt-get install \
      ca-certificates \
      curl \
      gnupg

   - name: install 2
     shell: |
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg

   - name: install 3
     shell: |
      echo \
      "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null  

   - name: install 4
     shell: |
      sudo apt-get update
      sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y  

   - name: run docker elasticsearch
     shell: |
      sudo docker network create elastic
      sudo docker run  -d --name elasticsearch --net elastic -p 9200:9200 -e discovery.type=single-node -e xpack.security.enabled=false elasticsearch:8.7.0
    EOT

    destination = "./elasticsearch-playbook.yml"
  }

  provisioner "file" {
    content = <<EOT
- hosts: kibana
  remote_user: ubuntu
  become: yes
  become_method: sudo

  tasks:
   - name: move kibana deb
     copy:
      src: kibana-8.7.0-amd64.deb
      dest: ./

   - name: install kibana
     apt:
      deb: kibana-8.7.0-amd64.deb

   - name: kibana edit yml
     copy:
      dest: "/etc/kibana/kibana.yml"
      content: |  
       server.port: 5601
       server.host: "0.0.0.0"
       elasticsearch.hosts: ["http://${yandex_compute_instance.vm-4.network_interface.0.ip_address}:9200"]

   - name: start kibana service
     service: 
      name: kibana.service 
      state: started  
      enabled: yes
    EOT

    destination = "./kibana-playbook.yml"
  }

  provisioner "file" {
    content = <<EOT
- hosts: prometheus
  remote_user: ubuntu
  become: yes
  become_method: sudo
  
  tasks:
    - name: Install prometheus
      apt:
        name: prometheus
        state: present

    - name: add Exporters
      blockinfile:
       path: /etc/prometheus/prometheus.yml
       block: |
        #add Node
          - job_name: 'Node_Exporter1'
            static_configs:
              - targets: ['${yandex_compute_instance_group.ig-1.instances.0.network_interface.0.ip_address}:9100']

          - job_name: 'Node_Exporter2'
            static_configs:
              - targets: ['${yandex_compute_instance_group.ig-1.instances.1.network_interface.0.ip_address}:9100']

          - job_name: 'nginxlog_Exporter1'
            static_configs:
              - targets: ['${yandex_compute_instance_group.ig-1.instances.0.network_interface.0.ip_address}:4040']

          - job_name: 'nginxlog_Exporter2'
            static_configs:
              - targets: ['${yandex_compute_instance_group.ig-1.instances.1.network_interface.0.ip_address}:4040']

    - name: restart prometheus
      service: 
       name: prometheus.service 
       state: restarted 
       enabled: yes
        
    EOT

    destination = "./prometheus-playbook.yml"
  }

  provisioner "file" {
    content = <<EOT
- hosts: grafana
  remote_user: ubuntu
  become: yes
  become_method: sudo

  tasks:
    - name: Install libfontconfig1
      apt:
        name: libfontconfig1
        state: present

    - name: Move grafana to vm
      copy:
       src: grafana-enterprise_9.4.7_amd64.deb
       dest: grafana-enterprise_9.4.7_amd64.deb
    
    - name: Install grafana
      apt:
        deb: grafana-enterprise_9.4.7_amd64.deb

    - name: Move
      copy:
       src: dashboard.json
       dest: /var/lib/grafana/dashboards/

    - name: Creating a file with content dashbord
      copy:
        dest: "/etc/grafana/provisioning/dashboards/default.yaml"
        content: |
         apiVersion: 1

         providers:
         - name: 'gdev dashboards'
           folder: 'gdev dashboards'
           folderUid: ''
           type: file
           updateIntervalSeconds: 10
           allowUiUpdates: false
           options:
             path: /var/lib/grafana/dashboards
          
    - name: Creating a file with content
      copy:
        dest: "/etc/grafana/provisioning/datasources/default.yaml"
        content: |
         apiVersion: 1

         datasources:
         - name: Prometheus
           type: prometheus
           access: proxy
           url: http://${yandex_compute_instance.vm-2.network_interface.0.ip_address}:9090
           jsonData:
            httpMethod: POST
            manageAlerts: true
            prometheusType: Prometheus
            prometheusVersion: 2.37.0
            exemplarTraceIdDestinations:
             - datasourceUid: my_jaeger_uid
               name: traceID

    - name: Start grafana
      service: 
       name: grafana-server.service
       state: started 
       enabled: yes
        
    EOT

    destination = "./grafana-playbook.yml"
  }

  provisioner "file" {
    content = <<EOT
    [Unit]
    Description=Node Exporter
    Wants=network-online.target
    After=network-online.target

    [Service]
    User=ubuntu
    Group=ubuntu
    Type=simple
    ExecStart=/usr/local/bin/node_exporter

    [Install]
    WantedBy=multi-user.target

    EOT

    destination = "./node_exporter.service"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt install ansible -y",
      "ansible-playbook nginx-playbook.yml -i host",
      "ansible-playbook prometheus-playbook.yml -i host",
      "ansible-playbook grafana-playbook.yml -i host",
      "ansible-playbook nodeinstall-playbook.yml -i host",
      "ansible-playbook elasticsearch-playbook.yml -i host",
      "ansible-playbook kibana-playbook.yml -i host",
      "ansible-playbook filebeatinstall-playbook.yml -i host",
    ]
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_compute_instance" "vm-2" {

  name        = "vm-prometheus"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8i3uauimpm750kd9vh"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-1.id
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_compute_instance" "vm-3" {

  name        = "vm-grafana"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8i3uauimpm750kd9vh"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-1.id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_compute_instance" "vm-4" {

  name        = "vm-elasticsearch"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8i3uauimpm750kd9vh"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-1.id
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_compute_instance" "vm-5" {

  name        = "vm-kibana"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "fd8i3uauimpm750kd9vh"
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.subnet-1.id
    nat       = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}


output "public_ip" {
  value = yandex_compute_instance.vm-1.network_interface.0.nat_ip_address
}


resource "yandex_compute_instance_group" "ig-1" {
  name               = "ig-1"
  service_account_id = "ajemk29m97hsrlbmbqe4"

  instance_template {
    platform_id = "standard-v3"
    resources {
      memory = 2
      cores  = 2
    }

    boot_disk {
      initialize_params {
        image_id = "fd8i3uauimpm750kd9vh"
        size     = 20
      }
    }

    network_interface {
      network_id = yandex_vpc_network.network-1.id
      subnet_ids = ["${yandex_vpc_subnet.subnet-1.id}", "${yandex_vpc_subnet.subnet-2.id}"]
    }

    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
    }
  }

  scale_policy {
    auto_scale {
      initial_size           = 2
      measurement_duration   = 60
      cpu_utilization_target = 75
      min_zone_size          = 1
      max_size               = 3
      warmup_duration        = 60
      stabilization_duration = 120
    }
  }

  allocation_policy {
    zones = ["ru-central1-a", "ru-central1-b"]
  }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }

  application_load_balancer {
    target_group_name        = "target-group"
    target_group_description = "load balancer target group"
  }
}

data "yandex_compute_instance" "my_instance1" {
  instance_id = yandex_compute_instance_group.ig-1.instances.0.instance_id
}

data "yandex_compute_instance" "my_instance2" {
  instance_id = yandex_compute_instance_group.ig-1.instances.1.instance_id
}

resource "yandex_compute_snapshot_schedule" "default" {
  name = "my-name"

  schedule_policy {
    expression = "0 1 * * *"
  }

  snapshot_count = 1

  snapshot_spec {
    description = "snapshot-description"
    labels = {
      snapshot-label = "my-snapshot-label-value"
    }
  }

  labels = {
    my-label = "my-label-value"
  }

  disk_ids = ["${yandex_compute_instance.vm-5.boot_disk.0.disk_id}", "${yandex_compute_instance.vm-4.boot_disk.0.disk_id}", "${yandex_compute_instance.vm-3.boot_disk.0.disk_id}", "${yandex_compute_instance.vm-2.boot_disk.0.disk_id}", "${yandex_compute_instance.vm-1.boot_disk.0.disk_id}", "${data.yandex_compute_instance.my_instance1.boot_disk.0.disk_id}", "${data.yandex_compute_instance.my_instance2.boot_disk.0.disk_id}"]
}

resource "yandex_alb_backend_group" "bg-1" {
  name = "bg-1"
  session_affinity {
    connection {
      source_ip = true
    }
  }

  http_backend {
    name   = "backend"
    weight = 1
    port   = 80

    target_group_ids = ["${yandex_compute_instance_group.ig-1.application_load_balancer.0.target_group_id}"]
    load_balancing_config {
      panic_threshold = 90
    }
    healthcheck {
      timeout             = "10s"
      interval            = "2s"
      healthy_threshold   = 10
      unhealthy_threshold = 15
      http_healthcheck {
        path = "/"
      }
    }
  }
}


resource "yandex_alb_http_router" "hr-1" {
  name = "hr-1"
  labels = {
    tf-label    = "lv-1"
    empty-label = ""
  }
}


resource "yandex_alb_virtual_host" "vh-1" {
  name           = "vh-1"
  http_router_id = yandex_alb_http_router.hr-1.id
  route {
    name = "r-1"
    http_route {
      http_route_action {
        backend_group_id = yandex_alb_backend_group.bg-1.id
        timeout          = "3s"
      }
    }
  }
}

resource "yandex_alb_load_balancer" "test-balancer" {
  name = "my-load-balancer"

  network_id = yandex_vpc_network.network-1.id

  allocation_policy {
    location {
      zone_id   = "ru-central1-a"
      subnet_id = yandex_vpc_subnet.subnet-1.id
    }

    location {
      zone_id   = "ru-central1-b"
      subnet_id = yandex_vpc_subnet.subnet-2.id
    }

  }

  listener {
    name = "my-listener"
    endpoint {
      address {
        external_ipv4_address {
        }
      }
      ports = [80]
    }
    http {
      handler {
        http_router_id = yandex_alb_http_router.hr-1.id
      }
    }
  }
}

resource "yandex_vpc_gateway" "default" {
  name = "foobar"
  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "rt" {
  name       = "rt"
  network_id = yandex_vpc_network.network-1.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.default.id
  }
}


resource "yandex_vpc_network" "network-1" {
  name = "network1"
}

resource "yandex_vpc_subnet" "subnet-1" {
  name           = "subnet1"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network-1.id
  v4_cidr_blocks = ["192.168.10.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}

resource "yandex_vpc_subnet" "subnet-2" {
  name           = "subnet2"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.network-1.id
  v4_cidr_blocks = ["192.168.11.0/24"]
  route_table_id = yandex_vpc_route_table.rt.id
}