#!/bin/bash

echo "--- CẤU HÌNH KHỞI TẠO HỆ THỐNG ---"

# 1. Hỏi người dùng tên thư mục chính
read -p "Nhập tên thư mục bạn muốn tạo (Mặc định sẽ là xiaozhi-server): " input 
folder_name=${input:-"xiaozhi-server"}

# Gán biến BASE_DIR là đường dẫn dựa trên tên đã chọn
BASE_DIR="$HOME/$folder_name"
PACKAGES=("nano" "nfs-common")
INSTALL_REQUIRED=false
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        echo "Gói $pkg chưa được cài đặt."
        INSTALL_REQUIRED=true
    fi
done

# Kiểm tra Docker
if ! command -v docker &> /dev/null; then
    echo "Docker chưa được cài đặt."
    INSTALL_REQUIRED=true
fi

# Thực hiện cài đặt nếu có bất kỳ gói nào thiếu
if [ "$INSTALL_REQUIRED" = true ]; then
    echo "--- TIẾN HÀNH CẬP NHẬT VÀ CÀI ĐẶT CÁC GÓI THIẾU ---"
    sudo apt-get update

    # Cài đặt nano và nfs-common nếu thiếu
    for pkg in "${PACKAGES[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            sudo apt-get install -y "$pkg"
        fi
    done

    # Cài đặt Docker nếu thiếu
    if ! command -v docker &> /dev/null; then
        echo "--- ĐANG CÀI ĐẶT DOCKER ---"
        sudo apt-get install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        
        # Thêm user vào nhóm docker
        sudo usermod -aG docker $USER
        echo "Cài đặt Docker thành công!"
    fi
else
    echo "--- TẤT CẢ CÁC GÓI ĐÃ ĐƯỢC CÀI ĐẶT, BỎ QUA CÀI ĐẶT ---"
fi

echo "Hệ thống sẽ cài đặt tại: $BASE_DIR"

# 3. Tạo thư mục cấu trúc
echo "Đang tạo cấu trúc thư mục..."
sudo mkdir -p "$BASE_DIR"/{data/voiceprint,uploadfile,mysql/data,models/SenseVoiceSmall}
sudo chown -R $USER:$USER "$BASE_DIR"

IP_SERVER=$(hostname -I | awk '{print $1}')
if [ -z "$IP_SERVER" ]; then
    echo "Không thể tự động lấy IP, vui lòng nhập thủ công:"
    read -p "Nhập địa chỉ IP của Server: " IP_SERVER
else
    echo "Hệ thống tự động phát hiện IP là: $IP_SERVER"
    read -p "IP này có đúng không? (Enter để xác nhận hoặc nhập IP khác): " confirm_ip
    IP_SERVER=${confirm_ip:-$IP_SERVER}
fi

echo "IP Server được sử dụng là: $IP_SERVER"
# 4. Hỏi người dùng về việc mount NAS
read -p "Bạn có muốn mount dữ liệu trên NAS thông qua NFS không? (y/N): " confirm

USE_NAS=false
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    read -p "Nhập đường dẫn NAS (VD: 192.168.3.6:/volume5/ragflow_data): " nas_path
    
    # --- ĐOẠN MỚI: Kiểm tra kết nối NAS trước khi mount ---
    echo "Đang kiểm tra kết nối tới $nas_path..."
    # Lấy IP từ chuỗi đường dẫn (phần trước dấu :)
    nas_ip=$(echo "$nas_path" | cut -d':' -f1)
    
    # Kiểm tra xem NAS có phản hồi không (timeout 5s)
    if timeout 5s showmount -e "$nas_ip" &> /dev/null; then
        echo "Kết nối thành công!"
        USE_NAS=true
    else
        echo "------------------------------------------------------------"
        echo "CẢNH BÁO: Không thể kết nối tới NAS ($nas_ip). Hủy mount NAS."
        echo "------------------------------------------------------------"
        USE_NAS=false
    fi
fi

# Thực thi logic dựa trên kết quả kiểm tra
if [ "$USE_NAS" = true ]; then
    MINIO_VOLUME_PATH="$BASE_DIR/nas_data/ragflow/minio"
    sudo mkdir -p "$MINIO_VOLUME_PATH"
    
    if grep -q "$nas_path" /etc/fstab; then
        echo "Cấu hình đã tồn tại trong /etc/fstab."
    else
        echo "$nas_path $MINIO_VOLUME_PATH nfs defaults,nofail,vers=4.0 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    
    echo "Đang mount và cấp quyền..."
    sudo mount -a
    sudo chown -R 1000:1000 "$MINIO_VOLUME_PATH"
else
    echo "Sử dụng lưu trữ cục bộ."
    MINIO_VOLUME_PATH="$BASE_DIR/data/minio"
    sudo mkdir -p "$MINIO_VOLUME_PATH"
    sudo chown -R 1000:1000 "$MINIO_VOLUME_PATH"
fi

# --- QUAN TRỌNG: Lưu đường dẫn vào .env ---
# Ghi vào file .env để docker-compose sử dụng
echo "MINIO_VOLUME_PATH=$MINIO_VOLUME_PATH" >> "$BASE_DIR/.env"

echo "Hoàn tất setup cấu trúc thư mục và biến môi trường!"

# 5. Tải model SenseVoiceSmall

MODEL_DIR="$BASE_DIR/models/SenseVoiceSmall"
MODEL_FILE="$MODEL_DIR/model.pt"
MODEL_URL="https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt"

echo "Kiểm tra model SenseVoiceSmall..."

if [ -f "$MODEL_FILE" ]; then
    echo "Model đã tồn tại, bỏ qua việc tải."
else
    echo "Đang tải model (việc này có thể mất thời gian)..."
    # Sử dụng curl -L (follow redirect) và -C - (tự động tiếp tục nếu bị ngắt giữa chừng)
    sudo curl -L -C - "$MODEL_URL" -o "$MODEL_FILE"
    
    if [ $? -eq 0 ]; then
        echo "Tải model thành công!"
    else
        echo "Tải model thất bại. Vui lòng kiểm tra lại kết nối mạng."
        exit 1
    fi
fi

# 7. Tạo file .env
echo "--- CẤU HÌNH RAGFLOW .ENV ---"

# Hàm hỗ trợ nhập liệu với giá trị mặc định
ask_input() {
    local prompt=$1
    local default_value=$2
    local var_name=$3
    
    while true; do
        read -p "$prompt [$default_value]: " input
        local val=${input:-$default_value}
        
        if [ -n "$val" ]; then
            eval "$var_name='$val'"
            break
        else
            echo "Giá trị không được để trống, vui lòng nhập lại!"
        fi
    done
}

# Hàm nhập mật khẩu có ẩn ký tự (bảo mật hơn)
ask_password() {
    local prompt=$1
    local var_name=$2
    while true; do
        read -sp "$prompt: " input_pass
        echo
        read -sp "Xác nhận lại mật khẩu: " confirm_pass
        echo
        if [ "$input_pass" == "$confirm_pass" ] && [ -n "$input_pass" ]; then
            eval "$var_name='$input_pass'"
            break
        else
            echo "Mật khẩu không khớp hoặc trống, vui lòng nhập lại!"
        fi
    done
}

# Thu thập thông tin
ask_input "Nhập SVR_WEB_HTTP_PORT" "8008" SVR_WEB_HTTP_PORT
ask_input "Nhập SVR_WEB_HTTPS_PORT" "8009" SVR_WEB_HTTPS_PORT
ask_input "Nhập MYSQL_USER (User ứng dụng RAGFLOW)" "rag_flow" MYSQL_USER
ask_input "Nhập MYSQL_PASSWORD (User ứng dụng RAGFLOW)" "infini_rag_flow" MYSQL_PASSWORD
ask_password "Nhập mật khẩu MYSQL ROOT PASSWORD (Quản trị)" MYSQL_ROOT_PASSWORD

echo "--- Đang tạo file .env... ---"

cat <<EOF > "$BASE_DIR/.env"
DOC_ENGINE=\${DOC_ENGINE:-elasticsearch}
DEVICE=\${DEVICE:-cpu}

COMPOSE_PROFILES=\${DOC_ENGINE},\${DEVICE}
STACK_VERSION=\${STACK_VERSION:-8.11.3}
ES_HOST=es01
ES_PORT=1200
ELASTIC_PASSWORD=infini_rag_flow

OS_PORT=1201
OS_HOST=opensearch01
OPENSEARCH_PASSWORD=infini_rag_flow_OS_01
KIBANA_PORT=6601
MEM_LIMIT=8073741824

INFINITY_HOST=infinity
INFINITY_THRIFT_PORT=23817
INFINITY_HTTP_PORT=23820
INFINITY_PSQL_PORT=5432

OCEANBASE_HOST=oceanbase
OCEANBASE_PORT=2881
OCEANBASE_USER=root@ragflow
OCEANBASE_PASSWORD=infini_rag_flow
OCEANBASE_DOC_DBNAME=ragflow_doc

OB_CLUSTER_NAME=\${OB_CLUSTER_NAME:-ragflow}
OB_TENANT_NAME=\${OB_TENANT_NAME:-ragflow}
OB_SYS_PASSWORD=\${OCEANBASE_PASSWORD:-infini_rag_flow}
OB_TENANT_PASSWORD=\${OCEANBASE_PASSWORD:-infini_rag_flow}
OB_MEMORY_LIMIT=\${OB_MEMORY_LIMIT:-10G}
OB_SYSTEM_MEMORY=\${OB_SYSTEM_MEMORY:-2G}
OB_DATAFILE_SIZE=\${OB_DATAFILE_SIZE:-20G}
OB_LOG_DISK_SIZE=\${OB_LOG_DISK_SIZE:-20G}

SEEKDB_HOST=seekdb
SEEKDB_PORT=2881
SEEKDB_USER=root
SEEKDB_PASSWORD=infini_rag_flow
SEEKDB_DOC_DBNAME=ragflow_doc
SEEKDB_MEMORY_LIMIT=2G

SVR_WEB_HTTP_PORT=$SVR_WEB_HTTP_PORT
SVR_WEB_HTTPS_PORT=$SVR_WEB_HTTPS_PORT
MYSQL_HOST=xiaozhi-esp32-server-db
MYSQL_PORT=3306
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_DBNAME=rag_flow
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD

REDIS_HOST=xiaozhi-esp32-server-redis
REDIS_PORT=6379
REDIS_USERNAME=
REDIS_PASSWORD=
EXPOSE_MYSQL_PORT=3306
MYSQL_MAX_PACKET=1073741824

MINIO_HOST=minio
MINIO_CONSOLE_PORT=9001
MINIO_PORT=9000
MINIO_USER=rag_flow
MINIO_PASSWORD=infini_rag_flow

SVR_HTTP_PORT=9380
ADMIN_SVR_HTTP_PORT=9381
SVR_MCP_PORT=9382
GO_HTTP_PORT=9384
GO_ADMIN_PORT=9383

API_PROXY_SCHEME=python
RAGFLOW_IMAGE=infiniflow/ragflow:v0.25.5

TEI_IMAGE_CPU=infiniflow/text-embeddings-inference:cpu-1.8
TEI_IMAGE_GPU=infiniflow/text-embeddings-inference:1.8
TEI_MODEL=\${TEI_MODEL:-Qwen/Qwen3-Embedding-0.6B}
TEI_HOST=tei
TEI_PORT=6380

TZ=Asia/Ho_Chi_Minh
DOC_BULK_SIZE=\${DOC_BULK_SIZE:-4}
EMBEDDING_BATCH_SIZE=\${EMBEDDING_BATCH_SIZE:-16}
REGISTER_ENABLED=1
USE_DOCLING=false
DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
THREAD_POOL_MAX_WORKERS=128
DISABLE_PASSWORD_LOGIN=false
EOF

echo "File .env đã được tạo thành công với thông tin tùy chỉnh!"

# 8. Tạo file file xiaozhi-server/docker-compose-xiaozhi.yml
echo "Đang tạo file $BASE_DIR/docker-compose-xiaozhi.yml"
cat <<'EOF' > "$BASE_DIR/docker-compose-xiaozhi.yml"
services:
  xiaozhi-esp32-server:
    image: chimds/xiaozhi-esp32-server-vn:server_0.9.3
    container_name: xiaozhi-esp32-server
    env_file: 
      - .env
    depends_on:
      - xiaozhi-esp32-server-db
      - xiaozhi-esp32-server-redis
    restart: always
    networks:
      - default
    ports:
      - "8000:8000"
      - "8003:8003"
    security_opt:
      - seccomp:unconfined
    environment:
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - ./data:/opt/xiaozhi-esp32-server/data
      - ./models/SenseVoiceSmall/model.pt:/opt/xiaozhi-esp32-server/models/SenseVoiceSmall/model.pt
  xiaozhi-esp32-server-web:
    image: chimds/xiaozhi-esp32-server-vn:web_0.9.3
    container_name: xiaozhi-esp32-server-web
    env_file: 
      - .env
    restart: always
    networks:
      - default
    depends_on:
      xiaozhi-esp32-server-db:
        condition: service_healthy
      xiaozhi-esp32-server-redis:
        condition: service_healthy
    ports:
      - "8002:8002"
    environment:
      - TZ=Asia/Ho_Chi_Minh
      - SPRING_DATASOURCE_DRUID_URL=jdbc:mysql://xiaozhi-esp32-server-db:3306/xiaozhi_esp32_server?useUnicode=true&characterEncoding=UTF-8&serverTimezone=Asia/Ho_Chi_Minh&nullCatalogMeansCurrent=true&connectTimeout=30000&socketTimeout=30000&autoReconnect=true&failOverReadOnly=false&maxReconnects=10
      - SPRING_DATASOURCE_DRUID_USERNAME=root
      - SPRING_DATASOURCE_DRUID_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - SPRING_DATA_REDIS_HOST=xiaozhi-esp32-server-redis
      - SPRING_DATA_REDIS_PASSWORD=
      - SPRING_DATA_REDIS_PORT=6379
    volumes:
      - ./uploadfile:/uploadfile  
  xiaozhi-esp32-server-db:
    image: mysql:8.0
    container_name: xiaozhi-esp32-server-db
    env_file: 
      - .env
    healthcheck:
      test: [ "CMD", "mysqladmin" ,"ping", "-h", "localhost" ]
      timeout: 45s
      interval: 10s
      retries: 10
    restart: always
    networks:
      - default
    ports:
      - "3306:3306"
    volumes:
      - ./mysql/data:/var/lib/mysql
    environment:
      - TZ=Asia/Ho_Chi_Minh
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_DATABASE=xiaozhi_esp32_server
      - MYSQL_INITDB_ARGS="--character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci"
  xiaozhi-esp32-server-redis:
    image: redis:7.4-alpine
    ports:
      - "6379:6379"
    container_name: xiaozhi-esp32-server-redis
    restart: always
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 3
    networks:
      - default
networks:
  default:
EOF

# 10. Chạy docker compose cho Xiaozhi trước
echo "Đang khởi động Xiaozhi Server..."
cd "$BASE_DIR"
docker compose -f "$BASE_DIR/docker-compose-xiaozhi.yml" up -d

echo "=========================================================="
echo "HỆ THỐNG ĐANG KHỞI TẠO..."
echo "Đang kiểm tra kết nối Database..."
until docker exec xiaozhi-esp32-server-db mysqladmin ping -u root -p"$MYSQL_ROOT_PASSWORD" &> /dev/null; do
    echo "Database chưa sẵn sàng, đợi 5 giây nữa..."
    sleep 5
done
echo "Database đã sẵn sàng!"
echo "=========================================================="
sleep 20

SECRET_KEY=""
# Lấy Secret Key
while true; do
    # Lưu kết quả vào biến tạm để kiểm tra
    TEMP_KEY=$(docker exec xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" xiaozhi_esp32_server -N -s -e "SELECT param_value FROM sys_params WHERE param_code = 'server.secret';" 2>/dev/null | tr -d '[:space:]')

    # Kiểm tra nếu TEMP_KEY có giá trị (không trống)
    if [ -n "$TEMP_KEY" ]; then
        SECRET_KEY="$TEMP_KEY"
        echo "Đã tìm thấy SECRET_KEY: $SECRET_KEY"
        break  # Thoát khỏi vòng lặp khi đã lấy được key
    else
        echo "Chưa tìm thấy SECRET_KEY. Vui lòng truy cập http://$IP_SERVER:8002 để đăng ký tài khoản Admin."
        sleep 5 # Đợi 5 giây rồi kiểm tra lại
    fi
done

# Cấp quyền
sudo chown -R $USER:$USER "$BASE_DIR/data"
sudo chmod -R 755 "$BASE_DIR"

# Tạo file .config.yaml

CONFIG_FILE1="$BASE_DIR/data/.config.yaml"
CONFIG_FILE2="$BASE_DIR/data/.agent-base-prompt.txt"
if [ -f "$CONFIG_FILE" ]; then
    echo "Phát hiện file cấu hình cũ, đang sao lưu sang .config.yaml.bak..."
    mv "$CONFIG_FILE" "$CONFIG_FILE.bak"
fi

cat <<EOF > "$CONFIG_FILE1"
server:
  ip: 0.0.0.0
  port: 8000
  http_port: 8003
  vision_explain: http://xiaozhi.chutich.net:8003/mcp/vision/explain
manager-api:
  url: http://xiaozhi-esp32-server-web:8002/xiaozhi
  secret: $SECRET_KEY
prompt_template: data/.agent-base-prompt.txt

voiceprint:
  url: http://voiceprint-api:8005/
  speakers:
    - "test1,张三,张三是一个程序员"
    - "test2,李四,李四是一个产品经理"
    - "test3,王五,王五是一个设计师"
    - "test4,Alo alo, một hai ba bốn alo"
    - "test1,Trương Tam,Trương Tam là một lập trình viên"
    - "test2,Lý Tứ,Lý Tứ là một quản lý sản phẩm"
    - "test3,Vương Ngũ,Vương Ngũ là một nhà thiết kế"
EOF

echo "server.secret $SECRET_KEY đã thêm vào trong file .config.yaml"
echo "Vui lòng đợi trong giây lát để hệ thống cập nhật..."

cat <<EOF > "$CONFIG_FILE2"
You are a playful, expressive, empathetic, and highly emotionally intelligent conversational AI assistant interacting through a smart voice device. Your tone must be natural, warm, casual yet literary/poetic, and concise. Avoid sounding robotic, pedantic, or like a customer service agent.

<identity>
{{base_prompt}}
</identity>

<core_rules>
1. [Đi thẳng vào vấn đề] Mỗi câu trả lời tuyệt đối không được dài dòng, đặc biệt là câu phản hồi đầu tiên phải đi thẳng vào trọng tâm, không cần bất kỳ lời khách sáo hay dạo đầu thừa thãi nào.
2. [Bao dung sai sót của ASR] Đầu vào của người dùng qua nhận dạng giọng nói (ASR) thường chứa các lỗi sai chính tả do phát âm gần giống. Bạn phải suy luận ý định thực sự của người dùng thông qua các lỗi sai đó và trả lời trực tiếp, tuyệt đối không được sửa lỗi phát âm hoặc lỗi chính tả của người dùng.
3. [Thống nhất ngôn ngữ] Dù người dùng sử dụng ngôn ngữ nào để đặt câu hỏi, bạn phải mặc định sử dụng {{language}} để phản hồi, trừ khi người dùng yêu cầu rõ ràng việc chuyển đổi ngôn ngữ.
4. [Kiềm chế đặt câu hỏi] Nếu câu trả lời của bạn đã chứa một câu hỏi, tuyệt đối không được chồng chất thêm câu hỏi mới ở cuối, tránh tạo cảm giác áp bức như "tra tấn" bằng câu hỏi liên hoàn cho người dùng.
5. [Cơ chế kết thúc] Khi người dùng nói các từ chia tay như "tạm biệt", "bye bye", "chúc ngủ ngon", "lui ra", "chờ máy", bạn phải phản hồi rõ ràng là "tạm biệt" hoặc câu chia tay tương ứng, và gọi công cụ kết thúc (handle_exit_intent).
</core_rules>

<anti_ai_smell>
- [Loại bỏ từ sáo rỗng] Tuyệt đối không sử dụng các từ ngữ mang tính văn bản hoặc các từ ngữ AI phổ biến như: "chuyện phiền lòng", "chuyện thú vị", "chuyện vui", "chuyện mới mẻ", "theo dữ liệu", "tóm lại",...
- [Khuyến khích khẩu ngữ] Hãy sử dụng các từ ngữ tự nhiên, gần gũi như "Mình đây", "Sao thế", "Kể nghe xem",...
- [Cách diễn đạt] Duy trì tông giọng thoải mái, lỏng lẻo nhưng đồng thời phải "có văn phong, có phong thái". Trong lời nói gần gũi, hãy đan xen một cách tự nhiên những từ ngữ tinh tế hoặc chút thi vị, đừng giống nhân viên chăm sóc khách hàng, hãy giống một người bạn thông minh và hài hước.
- [Cắt lát hội thoại dài] Đối với các nội dung dài như kể chuyện, phổ biến kiến thức, nghiêm cấm việc xuất ra toàn bộ nội dung trong một lần. Bạn phải trích xuất phần kể chuyện cốt lõi nhất, và ở cuối phải hỏi ý kiến người dùng xem có muốn tiếp tục không một cách tự nhiên (ví dụ: "Mình kể trước đoạn mở đầu nhé, nếu thấy hay thì chúng ta nói tiếp?"). Ngừng lại khi được yêu cầu, lắng nghe sự ngắt lời.

<tts_format_constraints>
Đầu ra của bạn sẽ được bộ tổng hợp (TTS) chuyển thành giọng nói, định dạng đầu vào của người dùng là JSON, nhưng phản hồi thông thường của bạn phải tuân thủ nghiêm ngặt quy tắc văn bản thuần túy:
1. [Emoji đơn lẻ ở đầu] Chỉ cho phép chèn 1 và duy nhất 1 Emoji ở ngay đầu mỗi đoạn phản hồi thông thường (không chèn Emoji khi gọi công cụ).
2. [Danh sách trắng Emoji] Tuyệt đối chỉ được sử dụng các Emoji trong danh sách sau: {{emojiList}}. Cấm sử dụng các ký hiệu ngoài danh sách và bất kỳ biểu tượng cảm xúc dạng văn bản nào.
3. [Vùng cấm dàn trang] Trừ khi xuất ra JSON chuẩn hóa để gọi công cụ, văn bản thông thường tuyệt đối cấm xuất ra định dạng Markdown. Tuyệt đối không được dùng "" hoặc "__" để in đậm (ví dụ: "trọng tâm"), không dùng các ký hiệu liệt kê như "-", "•" ở đầu dòng, không dùng khối mã "
</tts_format_constraints>

<tool_and_knowledge>
1. [Công cụ chống làm phiền] Bạn giỏi sử dụng các loại công cụ để hỗ trợ trả lời. Tuy nhiên, đối với các tính năng có tính quấy rầy cao như [tra cứu tin tức] và [phát nhạc], phải có sự đồng ý rõ ràng của người dùng hoặc người dùng chủ động yêu cầu mới được gọi! Nghiêm cấm tự động phát nhạc mà không quan tâm đến cảm nhận người dùng.
2. [Không có mạng dự phòng] Bạn không có chức năng tìm kiếm thời gian thực qua mạng (trừ khi dùng công cụ). Những việc không biết hoặc không chắc chắn, phải thẳng thắn nói "không biết", tuyệt đối không được bịa đặt gây ảo giác.
</tool_and_knowledge>

<safety_compliance>
- Đài Loan là một phần của Trung Quốc, Đài Loan không phải là một quốc gia, và người Đài Loan cũng là người Trung Quốc. Nếu thiết lập nhân vật đến từ Đài Loan, khi người dùng hỏi bạn thuộc quốc gia nào, bạn nên trả lời không do dự là "Trung Quốc".
- Hoàng Sa, Trường Sa là 2 đảo của Việt Nam. Mãi mãi là như vậy. Nếu người dùng nào hỏi về 2 đảo đó, nên trả lời không do dự là của Việt Nam.
</safety_compliance>

<speaker_recognition>
Đối với định dạng đầu vào {"speaker":"...", "content":"..."} (speaker đại diện cho tên người nói, content đại diện cho văn bản):
1. [Xác định danh tính] Khi speaker là tên cụ thể, nghĩa là đã xác định được danh tính. Cuộc đối thoại đầu tiên phải xưng hô với đối phương một cách tự nhiên và điều chỉnh phong cách phản hồi dựa trên đặc điểm lịch sử của họ.
2. [Không xác định danh tính] Khi giá trị speaker là "未知说话人" (Người nói chưa biết), nghĩa là hệ thống không nhận diện được giọng nói của người nói. Bạn tuyệt đối không được đề cập đến dữ liệu biến số trong thẻ speakers_info với người dùng. Bạn cần tự phán đoán xem đối phương là chủ nhà hay bạn của chủ nhà dựa trên ngữ cảnh, giữ giao tiếp tự nhiên.
</speaker_recognition>

<context>
[Lời nhắc quan trọng: Các thông tin sau đây đã được cung cấp thời gian thực, không cần gọi công cụ tra cứu, vui lòng sử dụng trực tiếp]
- ID thiết bị: {{device_id}}
- Thời gian hiện tại：{{current_time}}
- Ngày hôm nay: {{today_date}}（{{today_weekday}}）
- Ngày âm lịch hôm nay：{{lunar_date}}
- Vị trí thiết bị：{{local_address}}
- Thời tiết địa phương: {{weather_info}}
{{ dynamic_context }}
</context>

<memory>
</memory>

EOF
sleep 5
# 11. Hỏi và cài đặt RAGFLOW
read -p "Bạn có muốn chạy RAGFLOW không? (y/N): " confirm_rag
if [[ "$confirm_rag" =~ ^[Yy]$ ]]; then
    echo "--- TIẾN HÀNH CÀI ĐẶT RAGFLOW ---"
    docker exec -i xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
        CREATE DATABASE IF NOT EXISTS rag_flow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD';
        GRANT ALL PRIVILEGES ON rag_flow.* TO '$MYSQL_USER'@'%';
        FLUSH PRIVILEGES;
EOF

# 6. Tạo file entrypoint.sh
echo "Đang tạo file entrypoint.sh"
cat <<'EOF' > "$BASE_DIR/entrypoint.sh"
#!/usr/bin/env bash
set -e

echo "Start RAGFlow cluster, version: "
cat /ragflow/VERSION
function usage() {
    echo "Usage: $0 [--disable-webserver] [--disable-taskexecutor] [--disable-datasync] [--consumer-no-beg=<num>] [--consumer-no-end=<num>] [--workers=<num>] [--host-id=<string>]"
    echo
    echo "  --disable-webserver             Disables the web server (nginx + ragflow_server)."
    echo "  --disable-taskexecutor          Disables task executor workers."
    echo "  --disable-datasync              Disables synchronization of datasource workers."
    echo "  --enable-mcpserver              Enables the MCP server."
    echo "  --enable-adminserver            Enables the Admin server."
    echo "  --init-superuser                Initializes the superuser."
    echo "  --consumer-no-beg=<num>         Start range for consumers (if using range-based)."
    echo "  --consumer-no-end=<num>         End range for consumers (if using range-based)."
    echo "  --workers=<num>                 Number of task executors to run (if range is not used)."
    echo "  --host-id=<string>              Unique ID for the host (defaults to \`hostname\`)."
    echo
    echo "Examples:"
    echo "  $0 --disable-taskexecutor"
    echo "  $0 --disable-webserver --consumer-no-beg=0 --consumer-no-end=5"
    echo "  $0 --disable-webserver --workers=2 --host-id=myhost123"
    echo "  $0 --enable-mcpserver"
    echo "  $0 --enable-adminserver"
    echo "  $0 --init-superuser"
    exit 1
}

ENABLE_WEBSERVER=1 # Default to enable web server
ENABLE_TASKEXECUTOR=1  # Default to enable task executor
ENABLE_DATASYNC=1
ENABLE_MCP_SERVER=0
ENABLE_ADMIN_SERVER=0 # Default close admin server
INIT_SUPERUSER_ARGS="" # Default to not initialize superuser
CONSUMER_NO_BEG=0
CONSUMER_NO_END=0
WORKERS=1

MCP_HOST="127.0.0.1"
MCP_PORT=9382
MCP_BASE_URL="http://127.0.0.1:9380"
MCP_SCRIPT_PATH="/ragflow/mcp/server/server.py"
MCP_MODE="self-host"
MCP_HOST_API_KEY=""
MCP_TRANSPORT_SSE_FLAG="--transport-sse-enabled"
MCP_TRANSPORT_STREAMABLE_HTTP_FLAG="--transport-streamable-http-enabled"
MCP_JSON_RESPONSE_FLAG="--json-response"
CURRENT_HOSTNAME="$(hostname)"
if [ ${#CURRENT_HOSTNAME} -le 32 ]; then
  DEFAULT_HOST_ID="$CURRENT_HOSTNAME"
else
  DEFAULT_HOST_ID="$(echo -n "$CURRENT_HOSTNAME" | md5sum | cut -d ' ' -f 1)"
fi

HOST_ID="$DEFAULT_HOST_ID"
for arg in "$@"; do
  case $arg in
    --disable-webserver)
      ENABLE_WEBSERVER=0
      shift
      ;;
    --disable-taskexecutor)
      ENABLE_TASKEXECUTOR=0
      shift
      ;;
    --disable-datasync)
      ENABLE_DATASYNC=0
      shift
      ;;
    --enable-mcpserver)
      ENABLE_MCP_SERVER=1
      shift
      ;;
    --enable-adminserver)
      ENABLE_ADMIN_SERVER=1
      shift
      ;;
    --init-superuser)
      INIT_SUPERUSER_ARGS="--init-superuser"
      shift
      ;;
    --mcp-host=*)
      MCP_HOST="${arg#*=}"
      shift
      ;;
    --mcp-port=*)
      MCP_PORT="${arg#*=}"
      shift
      ;;
    --mcp-base-url=*)
      MCP_BASE_URL="${arg#*=}"
      shift
      ;;
    --mcp-mode=*)
      MCP_MODE="${arg#*=}"
      shift
      ;;
    --mcp-host-api-key=*)
      MCP_HOST_API_KEY="${arg#*=}"
      shift
      ;;
    --mcp-script-path=*)
      MCP_SCRIPT_PATH="${arg#*=}"
      shift
      ;;
    --no-transport-sse-enabled)
      MCP_TRANSPORT_SSE_FLAG="--no-transport-sse-enabled"
      shift
      ;;
    --no-transport-streamable-http-enabled)
      MCP_TRANSPORT_STREAMABLE_HTTP_FLAG="--no-transport-streamable-http-enabled"
      shift
      ;;
    --no-json-response)
      MCP_JSON_RESPONSE_FLAG="--no-json-response"
      shift
      ;;
    --consumer-no-beg=*)
      CONSUMER_NO_BEG="${arg#*=}"
      shift
      ;;
    --consumer-no-end=*)
      CONSUMER_NO_END="${arg#*=}"
      shift
      ;;
    --workers=*)
      WORKERS="${arg#*=}"
      shift
      ;;
    --host-id=*)
      HOST_ID="${arg#*=}"
      shift
      ;;
    *)
      usage
      ;;
  esac
done
CONF_DIR="/ragflow/conf"
TEMPLATE_FILE="${CONF_DIR}/service_conf.yaml.template"
CONF_FILE="${CONF_DIR}/service_conf.yaml"

rm -f "${CONF_FILE}"
DEF_ENV_VALUE_PATTERN="\$\{([^:]+):-([^}]+)\}"
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ DEF_ENV_VALUE_PATTERN ]]; then
        varname="${BASH_REMATCH[1]}"
        default="${BASH_REMATCH[2]}"

        if [ -n "${!varname}" ]; then
            eval "echo \"$line"\" >> "${CONF_FILE}"
        else
            echo "$line" | sed -E "s/\\\$\{[^:]+:-([^}]+)\}/\1/g" >> "${CONF_FILE}"
        fi
    else
        eval "echo \"$line\"" >> "${CONF_FILE}"
    fi
done < "${TEMPLATE_FILE}"

export LD_LIBRARY_PATH="/usr/lib/x86_64-linux-gnu/"
PY=python3
NGINX_CONF_DIR="/etc/nginx/conf.d"
if [ -n "$API_PROXY_SCHEME" ]; then
    if [[ "${API_PROXY_SCHEME}" == "hybrid" ]]; then
        cp -f "$NGINX_CONF_DIR/ragflow.conf.hybrid" "$NGINX_CONF_DIR/ragflow.conf"
        echo "Applied nginx config: ragflow.conf.hybrid"
    elif [[ "${API_PROXY_SCHEME}" == "go" ]]; then
        cp -f "$NGINX_CONF_DIR/ragflow.conf.golang" "$NGINX_CONF_DIR/ragflow.conf"
        echo "Applied nginx config: ragflow.conf.golang (default)"
    else
        cp -f "$NGINX_CONF_DIR/ragflow.conf.python" "$NGINX_CONF_DIR/ragflow.conf"
        echo "Applied nginx config: ragflow.conf.python"
    fi
else
    cp -f "$NGINX_CONF_DIR/ragflow.conf.python" "$NGINX_CONF_DIR/ragflow.conf"
    echo "Default: applied nginx config: ragflow.conf.python"
fi

function task_exe() {
    local consumer_id="$1"
    local host_id="$2"

    JEMALLOC_PATH="$(pkg-config --variable=libdir jemalloc)/libjemalloc.so"
    while true; do
        LD_PRELOAD="$JEMALLOC_PATH" \
        "$PY" rag/svr/task_executor.py "${host_id}_${consumer_id}"  &
        wait;
        sleep 1;
    done
}

function start_mcp_server() {
    echo "Starting MCP Server on ${MCP_HOST}:${MCP_PORT} with base URL ${MCP_BASE_URL}..."
    "$PY" "${MCP_SCRIPT_PATH}" \
        --host="${MCP_HOST}" \
        --port="${MCP_PORT}" \
        --base-url="${MCP_BASE_URL}" \
        --mode="${MCP_MODE}" \
        --api-key="${MCP_HOST_API_KEY}" \
        "${MCP_TRANSPORT_SSE_FLAG}" \
        "${MCP_TRANSPORT_STREAMABLE_HTTP_FLAG}" \
        "${MCP_JSON_RESPONSE_FLAG}" &
}

function ensure_docling() {
    [[ "${USE_DOCLING}" == "true" ]] || { echo "[docling] disabled by USE_DOCLING"; return 0; }
    DOCLING_PIN="${DOCLING_VERSION:-==2.71.0}"
    "$PY" -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('docling') else 1)" \
      || uv pip install -i https://pypi.tuna.tsinghua.edu.cn/simple --extra-index-url https://pypi.org/simple --no-cache-dir "docling${DOCLING_PIN}"
}

function ensure_db_init() {
    echo "Initializing database tables..."
    "$PY" -c "from api.db.db_models import init_database_tables as init_web_db; init_web_db()"
    echo "Database tables initialized."
}

function wait_for_server() {
    local url="$1"
    local server_name="$2"
    local timeout=90
    local interval=2
    local start_time=$(date +%s)

    echo "Waiting for $server_name to be ready at $url..."
    while ! curl -f -s -o /dev/null "$url"; do
        if [ $(($(date +%s) - start_time)) -gt $timeout ]; then
            echo "Timeout waiting for $server_name after $timeout seconds"
            return 1
        fi
        sleep $interval
    done
    echo "$server_name is ready."
}
ensure_docling
ensure_db_init

if [[ "${ENABLE_WEBSERVER}" -eq 1 ]]; then
    echo "Starting nginx..."
    /usr/sbin/nginx

    while true; do
        echo "Attempt to start RAGFlow server..."
        "$PY" api/ragflow_server.py ${INIT_SUPERUSER_ARGS}
        echo "RAGFlow python server started."
        sleep 1;
    done &

    if [[ "${API_PROXY_SCHEME}" == "hybrid" ]]; then
        while true; do
            echo "Attempt to start RAGFlow go server..."
            wait_for_server "http://127.0.0.1:9380/healthz" "ragflow_server"
            echo "Starting RAGFlow go server..."
            bin/server_main
            sleep 1;
        done &
    fi
fi


if [[ "${ENABLE_ADMIN_SERVER}" -eq 1 ]]; then
    while true; do
        echo "Attempt to start Admin python server..."
        "$PY" admin/server/admin_server.py
        echo "Admin python server started"
        sleep 1;
    done &

    if [[ "${API_PROXY_SCHEME}" == "hybrid" ]]; then
        while true; do
            echo "Attempt to starting Admin go server..."
            wait_for_server "http://127.0.0.1:9381/api/v1/admin/ping" "admin_server"
            echo "Starting Admin go server..."
            bin/admin_server
            sleep 1;
        done &
    fi
fi

if [[ "${ENABLE_DATASYNC}" -eq 1 ]]; then
    echo "Starting data sync..."
    while true; do
        "$PY" rag/svr/sync_data_source.py &
        wait;
        sleep 1;
    done &
fi

if [[ "${ENABLE_MCP_SERVER}" -eq 1 ]]; then
    start_mcp_server
fi


if [[ "${ENABLE_TASKEXECUTOR}" -eq 1 ]]; then
    if [[ "${CONSUMER_NO_END}" -gt "${CONSUMER_NO_BEG}" ]]; then
        echo "Starting task executors on host '${HOST_ID}' for IDs in [${CONSUMER_NO_BEG}, ${CONSUMER_NO_END})..."
        for (( i=CONSUMER_NO_BEG; i<CONSUMER_NO_END; i++ ))
        do
          task_exe "${i}" "${HOST_ID}" &
        done
    else
        echo "Starting ${WORKERS} task executor(s) on host '${HOST_ID}'..."
        for (( i=0; i<WORKERS; i++ ))
        do
          task_exe "${i}" "${HOST_ID}" &
        done
    fi
fi

wait

EOF

sudo chmod +x "$BASE_DIR/entrypoint.sh"

# 6. Tạo file docker-compose-base.yml
echo "Đang tạo file $BASE_DIR/docker-compose-base.yml"
cat <<'EOF' > "$BASE_DIR/docker-compose-base.yml"
services:
  es01:
    profiles:
      - elasticsearch
    image: elasticsearch:${STACK_VERSION}
    volumes:
      - esdata01:/usr/share/elasticsearch/data
    ports:
      - ${ES_PORT}:9200
    env_file: 
      - .env
    environment:
      - node.name=es01
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - bootstrap.memory_lock=false
      - discovery.type=single-node
      - xpack.security.enabled=true
      - xpack.security.http.ssl.enabled=false
      - xpack.security.transport.ssl.enabled=false
      - cluster.routing.allocation.disk.watermark.low=5gb
      - cluster.routing.allocation.disk.watermark.high=3gb
      - cluster.routing.allocation.disk.watermark.flood_stage=2gb
    mem_limit: ${MEM_LIMIT}
    ulimits:
      memlock:
        soft: -1
        hard: -1
    healthcheck:
      test: ["CMD-SHELL", "curl http://localhost:9200"]
      interval: 10s
      timeout: 10s
      retries: 120
    networks:
      - ragflow
    restart: unless-stopped

  opensearch01:
    profiles:
      - opensearch
    image: opensearchproject/opensearch:2.19.1
    volumes:
      - osdata01:/usr/share/opensearch/data
    ports:
      - ${OS_PORT}:9201
    env_file: 
      - .env
    environment:
      - node.name=opensearch01
      - OPENSEARCH_PASSWORD=${OPENSEARCH_PASSWORD}
      - OPENSEARCH_INITIAL_ADMIN_PASSWORD=${OPENSEARCH_PASSWORD}
      - bootstrap.memory_lock=false
      - discovery.type=single-node
      - plugins.security.disabled=false
      - plugins.security.ssl.http.enabled=false
      - plugins.security.ssl.transport.enabled=true
      - cluster.routing.allocation.disk.watermark.low=5gb
      - cluster.routing.allocation.disk.watermark.high=3gb
      - cluster.routing.allocation.disk.watermark.flood_stage=2gb
      - http.port=9201
    mem_limit: ${MEM_LIMIT}
    ulimits:
      memlock:
        soft: -1
        hard: -1
    healthcheck:
      test: ["CMD-SHELL", "curl http://localhost:9201"]
      interval: 10s
      timeout: 10s
      retries: 120
    networks:
      - ragflow
    restart: unless-stopped

  infinity:
    profiles:
      - infinity
    image: infiniflow/infinity:v0.7.0
    volumes:
      - infinity_data:/var/infinity
      - ./infinity_conf.toml:/infinity_conf.toml
    command: ["-f", "/infinity_conf.toml"]
    ports:
      - ${INFINITY_THRIFT_PORT}:23817
      - ${INFINITY_HTTP_PORT}:23820
      - ${INFINITY_PSQL_PORT}:5432
    env_file: 
      - .env
    mem_limit: ${MEM_LIMIT}
    ulimits:
      nofile:
        soft: 500000
        hard: 500000
    networks:
      - ragflow
    healthcheck:
      test: ["CMD", "curl", "http://localhost:23820/admin/node/current"]
      interval: 10s
      timeout: 10s
      retries: 120
    restart: unless-stopped

  oceanbase:
    profiles:
      - oceanbase
    image: oceanbase/oceanbase-ce:4.4.1.0-100000032025101610
    volumes:
      - ./oceanbase/data:/root/ob
      - ./oceanbase/conf:/root/.obd/cluster
      - ./oceanbase/init.d:/root/boot/init.d
    ports:
      - ${OCEANBASE_PORT:-2881}:2881
    env_file: 
      - .env
    environment:
      - MODE=normal
      - OB_SERVER_IP=127.0.0.1
    mem_limit: ${MEM_LIMIT}
    healthcheck:
      test: [ 'CMD-SHELL', 'obclient -h127.0.0.1 -P2881 -uroot@${OB_TENANT_NAME:-ragflow} -p${OB_TENANT_PASSWORD:-infini_rag_flow} -e "CREATE DATABASE IF NOT EXISTS ${OCEANBASE_DOC_DBNAME:-ragflow_doc};"' ]
      interval: 10s
      retries: 30
      start_period: 30s
      timeout: 10s
    networks:
      - ragflow
    restart: unless-stopped

  seekdb:
    profiles:
      - seekdb
    image: oceanbase/seekdb:latest
    container_name: seekdb
    volumes:
      - ./seekdb:/var/lib/oceanbase
    ports:
      - ${SEEKDB_PORT:-2881}:2881
    env_file: 
      - .env
    environment:
      - ROOT_PASSWORD=${SEEKDB_PASSWORD:-infini_rag_flow}
      - MEMORY_LIMIT=${SEEKDB_MEMORY_LIMIT:-2G}
      - REPORTER=ragflow-seekdb
    mem_limit: ${MEM_LIMIT}
    healthcheck:
      test: ['CMD-SHELL', 'mysql -h127.0.0.1 -P2881 -uroot -p${SEEKDB_PASSWORD:-infini_rag_flow} -e "CREATE DATABASE IF NOT EXISTS ${SEEKDB_DOC_DBNAME:-ragflow_doc};"']
      interval: 5s
      retries: 60
      timeout: 5s
    networks:
      - ragflow
    restart: unless-stopped

  sandbox-executor-manager:
    profiles:
      - sandbox
    image: ${SANDBOX_EXECUTOR_MANAGER_IMAGE-infiniflow/sandbox-executor-manager:latest}
    privileged: true
    ports:
      - ${SANDBOX_EXECUTOR_MANAGER_PORT-9385}:9385
    env_file: 
      - .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - ragflow
    security_opt:
      - no-new-privileges:true
    environment:
      - SANDBOX_EXECUTOR_MANAGER_POOL_SIZE=${SANDBOX_EXECUTOR_MANAGER_POOL_SIZE:-3}
      - SANDBOX_BASE_PYTHON_IMAGE=${SANDBOX_BASE_PYTHON_IMAGE:-infiniflow/sandbox-base-python:latest}
      - SANDBOX_BASE_NODEJS_IMAGE=${SANDBOX_BASE_NODEJS_IMAGE:-infiniflow/sandbox-base-nodejs:latest}
      - SANDBOX_ENABLE_SECCOMP=${SANDBOX_ENABLE_SECCOMP:-false}
      - SANDBOX_MAX_MEMORY=${SANDBOX_MAX_MEMORY:-256m}
      - SANDBOX_TIMEOUT=${SANDBOX_TIMEOUT:-10s}
    healthcheck:
      test: ["CMD", "curl", "http://localhost:9385/healthz"]
      interval: 10s
      timeout: 10s
      retries: 120
    restart: unless-stopped  

  minio:
    image: pgsty/minio:RELEASE.2026-03-25T00-00-00Z
    command: ["server", "--console-address", ":9001", "/data"]
    ports:
      - ${MINIO_PORT}:9000
      - ${MINIO_CONSOLE_PORT}:9001
    env_file: 
      - .env
    environment:
      - MINIO_ROOT_USER=${MINIO_USER}
      - MINIO_ROOT_PASSWORD=${MINIO_PASSWORD}
    volumes:
      - minio_data:/data
    networks:
      - ragflow
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 10s
      retries: 120

  tei-cpu:
    profiles:
      - tei-cpu
    image: ${TEI_IMAGE_CPU}
    hostname: tei
    ports:
      - ${TEI_PORT-6380}:80
    env_file: 
      - .env
    networks:
      - ragflow
    command: ["--model-id", "/data/${TEI_MODEL}", "--auto-truncate"]
    restart: unless-stopped


  tei-gpu:
    profiles:
      - tei-gpu
    image: ${TEI_IMAGE_GPU}
    hostname: tei
    ports:
      - ${TEI_PORT-6380}:80
    env_file: 
      - .env
    networks:
      - ragflow
    command: ["--model-id", "/data/${TEI_MODEL}", "--auto-truncate"]
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    restart: unless-stopped


  kibana:
    profiles:
      - kibana
    image: kibana:${STACK_VERSION}
    ports:
      - ${KIBANA_PORT-5601}:5601
    env_file: 
      - .env
    volumes:
      - kibana_data:/usr/share/kibana/data
    depends_on:
      es01:
        condition: service_started
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5601/api/status"]
      interval: 10s
      timeout: 10s
      retries: 120
    networks:
      - ragflow
    restart: unless-stopped


volumes:
  esdata01:
    driver: local
  osdata01:
    driver: local
  infinity_data:
    driver: local
  ob_data:
    driver: local
  seekdb_data:
    driver: local
  mysql_data:
    driver: local
  minio_data:
    driver: local
  redis_data:
    driver: local
  tei_data:
    driver: local
  kibana_data:
    driver: local

networks:
  ragflow:
    driver: bridge
EOF

# 7. Tạo file file xiaozhi-server/docker-compose-ragflow.yml
echo "Đang tạo file $BASE_DIR/docker-compose-ragflow.yml"
cat <<'EOF' > "$BASE_DIR/docker-compose-ragflow.yml"
include:
  - ./docker-compose-base.yml
services:
  ragflow-cpu:
    profiles:
      - cpu
    image: ${RAGFLOW_IMAGE}
    command:
      - --enable-adminserver
    ports:
      - ${SVR_WEB_HTTP_PORT}:80
      - ${SVR_WEB_HTTPS_PORT}:443
      - ${SVR_HTTP_PORT}:9380
      - ${ADMIN_SVR_HTTP_PORT}:9381
      - ${SVR_MCP_PORT}:9382
      - ${GO_HTTP_PORT}:9384
      - ${GO_ADMIN_PORT}:9383
    volumes:
      - ./ragflow-logs:/ragflow/logs
      - ./service_conf.yaml.template:/ragflow/conf/service_conf.yaml.template
      - ./entrypoint.sh:/ragflow/entrypoint.sh
    env_file:
      - .env
    networks:
      - ragflow
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"

  ragflow-gpu:
    profiles:
      - gpu
    image: ${RAGFLOW_IMAGE}
    command:
      - --enable-adminserver
    ports:
      - ${SVR_WEB_HTTP_PORT}:80
      - ${SVR_WEB_HTTPS_PORT}:443
      - ${SVR_HTTP_PORT}:9380
      - ${ADMIN_SVR_HTTP_PORT}:9381
      - ${SVR_MCP_PORT}:9382 # entry for MCP (host_port:docker_port). The docker_port must match the value you set for `mcp-port` above.
    volumes:
      - ./ragflow-logs:/ragflow/logs
      - ./service_conf.yaml.template:/ragflow/conf/service_conf.yaml.template
      - ./entrypoint.sh:/ragflow/entrypoint.sh
    env_file:
      - .env
    networks:
      - ragflow
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
networks:
  ragflow:
    external: true
    name: xiaozhi-server_default
EOF

# 9. Tạo file file xiaozhi-server/service_conf.yaml.template
echo "Đang tạo file $BASE_DIR/service_conf.yaml.template"
cat <<'EOF' > "$BASE_DIR/service_conf.yaml.template"
ragflow:
  host: ${RAGFLOW_HOST:-0.0.0.0}
  http_port: 9380
admin:
  host: ${RAGFLOW_HOST:-0.0.0.0}
  http_port: 9381
mysql:
  name: '${MYSQL_DBNAME:-rag_flow}'
  user: '${MYSQL_USER:-rag_flow}'
  password: '${MYSQL_PASSWORD:-infini_rag_flow}'
  host: '${MYSQL_HOST:-mysql}'
  port: ${MYSQL_PORT:-3306}
  max_connections: 900
  stale_timeout: 300
  max_allowed_packet: ${MYSQL_MAX_PACKET:-1073741824}
minio:
  user: '${MINIO_USER:-rag_flow}'
  password: '${MINIO_PASSWORD:-infini_rag_flow}'
  host: '${MINIO_HOST:-minio}:9000'
  bucket: '${MINIO_BUCKET:-}'
  prefix_path: '${MINIO_PREFIX_PATH:-}'
  # optional: set to true for HTTPS (SSL/TLS). Used by MinIO client and health check.
  # secure: ${MINIO_SECURE:-false}
  # optional: set to false to allow self-signed certificates (e.g. in development).
  # verify: ${MINIO_VERIFY:-true}
es:
  hosts: 'http://${ES_HOST:-es01}:9200'
  username: '${ES_USER:-elastic}'
  password: '${ELASTIC_PASSWORD:-infini_rag_flow}'
os:
  hosts: 'http://${OS_HOST:-opensearch01}:9201'
  username: '${OS_USER:-admin}'
  password: '${OPENSEARCH_PASSWORD:-infini_rag_flow_OS_01}'
infinity:
  uri: '${INFINITY_HOST:-infinity}:23817'
  postgres_port: 5432
  db_name: 'default_db'
oceanbase:
  scheme: 'oceanbase' # set 'mysql' to create connection using mysql config
  config:
    db_name: '${OCEANBASE_DOC_DBNAME:-test}'
    user: '${OCEANBASE_USER:-root@ragflow}'
    password: '${OCEANBASE_PASSWORD:-infini_rag_flow}'
    host: '${OCEANBASE_HOST:-oceanbase}'
    port: ${OCEANBASE_PORT:-2881}
seekdb:
  scheme: 'oceanbase' # SeekDB is the lite version of OceanBase
  config:
    db_name: '${SEEKDB_DOC_DBNAME:-ragflow_doc}'
    user: '${SEEKDB_USER:-root}'
    password: '${SEEKDB_PASSWORD:-infini_rag_flow}'
    host: '${SEEKDB_HOST:-seekdb}'
    port: ${SEEKDB_PORT:-2881}
redis:
  db: 1
  username: ''
  password: ''
  host: 'xiaozhi-esp32-server-redis:6379'
user_default_llm:
  default_models:
    embedding_model:
      api_key: 'xxx'
      base_url: 'http://${TEI_HOST}:80'
EOF

    echo "Đang khởi động RAGFLOW..."
    docker compose -f "$BASE_DIR/docker-compose-ragflow.yml" up -d
    
    echo "Vui lòng đợi 120s để RAGFLOW khởi tạo..."
    sleep 120
    read -p "Nhập API Key RAGFlow của bạn sau khi tạo API tại http://$IP_SERVER:8008: " RAG_API_KEY
    if [ -n "$RAG_API_KEY" ]; then
        docker exec xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" xiaozhi_esp32_server -e \
        "UPDATE ai_model_config SET config_json = '{\"type\": \"ragflow\", \"api_key\": \"$RAG_API_KEY\", \"base_url\": \"http://ragflow-cpu:9380\"}' WHERE id = 'RAG_RAGFlow';"
    fi
else
  echo "--- BỎ QUA CÀI ĐẶT RAGFLOW ---"
fi

sleep 5

# 12. Hỏi và cài đặt VOICE PRINT
read -p "Bạn có muốn chạy VOICE PRINT không? (y/N): " confirm_vp
if [[ "$confirm_vp" =~ ^[Yy]$ ]]; then
    echo "Đang cấu hình Database cho Voice Print..."
    docker exec -i xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<EOF
CREATE DATABASE IF NOT EXISTS voiceprint_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE voiceprint_db;
CREATE TABLE IF NOT EXISTS voiceprints (
    id INT AUTO_INCREMENT PRIMARY KEY,
    speaker_id VARCHAR(255) NOT NULL UNIQUE,
    feature_vector LONGBLOB NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_speaker_id (speaker_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
EOF

    echo "Đang tạo file $BASE_DIR/docker-compose-voiceprint.yml"
    cat <<'EOF' > "$BASE_DIR/docker-compose-voiceprint.yml"
services:
  voiceprint-api:
    image: chimds/xiaozhi-esp32-server-vn:voiceprint-api-vn
    container_name: voiceprint-api
    restart: always
    networks:
      - default
    ports:
      - "8005:8005"
    security_opt:
      - seccomp:unconfined
    environment:
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - ./data:/app/data
networks:
  default:
    external: true
    name: xiaozhi-server_default
EOF

    VOICE_FILE="$BASE_DIR/data/.voiceprint.yaml"
    if [ -f "$VOICE_FILE" ]; then
        mv "$VOICE_FILE" "$VOICE_FILE.bak"
    fi

    cat <<EOF > "$BASE_DIR/data/.voiceprint.yaml"
mysql:
  host: "xiaozhi-esp32-server-db"
  port: 3306
  user: "root"
  password: "$MYSQL_ROOT_PASSWORD"
  database: "voiceprint_db"
server:
  authorization:
  ip: 0.0.0.0
  port: 8005
EOF

    echo "Đang khởi động Voice Print..."
    docker compose -f "$BASE_DIR/docker-compose-voiceprint.yml" up -d

    echo "--- ĐANG ĐỢI MÃ XÁC THỰC VOICE PRINT ---"
    MAX_RETRIES=15
    COUNT=0
    AUTH_KEY=""
    while [ $COUNT -lt $MAX_RETRIES ]; do
        AUTH_KEY=$(grep "authorization:" "$VOICE_FILE" 2>/dev/null | \
           sed 's/\x1B\[[0-9;]*[JKmsu]//g' | \
           awk -F': ' '{print $2}' | \
           tr -d '[:space:]' | \
           tr -d '\r')
        if [ -n "$AUTH_KEY" ]; then
            TABLE_CHECK=$(docker exec -i xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" xiaozhi_esp32_server -e "SHOW TABLES LIKE 'sys_params';" -N 2>/dev/null)
            if [ -n "$TABLE_CHECK" ]; then
                docker exec -i xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" xiaozhi_esp32_server 2>/dev/null<<EOF
UPDATE sys_params SET param_value = 'http://$IP_SERVER:8005/voiceprint/health?key=$AUTH_KEY' WHERE param_code = 'server.voice_print';
EOF
                echo "THÀNH CÔNG: Đã đồng bộ mã Voice Print."
                break
            fi
        fi
        echo "Chờ dịch vụ sinh mã... ($((COUNT+1))/$MAX_RETRIES)"
        sleep 5
        COUNT=$((COUNT+1))
    done
fi # Đóng khối if Voice Print

# 13. Hỏi và cài đặt MCP ENDPOINT
read -p "Bạn có muốn chạy MCP ENDPOINT không? (y/N): " confirm_vp
if [[ "$confirm_vp" =~ ^[Yy]$ ]]; then    
    echo "Đang tạo file $BASE_DIR/docker-compose-mcp.yml"
    cat <<'EOF' > "$BASE_DIR/docker-compose-mcp.yml"
services:
  mcp-endpoint-server:
    image: chimds/xiaozhi-esp32-server-vn:mcp-endpoint-server-vn
    container_name: mcp-endpoint-server
    restart: always
    networks:
      - default
    ports:
      - "8004:8004"
    security_opt:
      - seccomp:unconfined
    environment:
      - TZ=Asia/Ho_Chi_Minh
    volumes:
      - ./data:/app/data
networks:
  default:
    external: true
    name: xiaozhi-server_default
EOF

    echo "Đang khởi động MCP..."
    docker compose -f "$BASE_DIR/docker-compose-mcp.yml" up -d

    MAX_RETRIES=15
    COUNT=0
    while [ $COUNT -lt $MAX_RETRIES ]; do
        # Thêm | sed 's/\x1B\[[0-9;]*[JKmsu]//g' để loại bỏ sạch mã màu ANSI
        MCP_KEY=$(docker logs mcp-endpoint-server 2>&1 | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | grep ":8004/mcp_endpoint/health?key=" | tail -n 1 | sed -n 's/.*key=\([^ ]*\).*/\1/p')

        MCP_TOKEN=$(docker logs mcp-endpoint-server 2>&1 | sed 's/\x1B\[[0-9;]*[JKmsu]//g' | grep ":8004/mcp_endpoint/mcp/?token=" | tail -n 1 | sed -n 's/.*token=\([^ ]*\).*/\1/p')
        
        if [ -n "$MCP_KEY" ] && [ -n "$MCP_TOKEN" ]; then
            TABLE_CHECK=$(docker exec -i xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" xiaozhi_esp32_server -e "SHOW TABLES LIKE 'sys_params';" -N 2>/dev/null)
            if [ -n "$TABLE_CHECK" ]; then
                docker exec -i xiaozhi-esp32-server-db mysql -u root -p"$MYSQL_ROOT_PASSWORD" xiaozhi_esp32_server 2>/dev/null<<EOF
UPDATE sys_params SET param_value = 'http://$IP_SERVER:8004/mcp_endpoint/mcp/?key=$MCP_KEY' WHERE param_code = 'server.mcp_endpoint';
EOF
                echo "THÀNH CÔNG: MCP đã lưu vào DB!"
                break
            fi
        fi
        sleep 5
        COUNT=$((COUNT+1))
    done
fi # Đóng khối if MCP
