import cv2
import mediapipe as mp
import time
import threading
import math
import numpy as np
from flask import Flask
from flask_socketio import SocketIO

# ==================== 1. 高级配置区域 ====================
HOST_IP = '0.0.0.0'
PORT = 5000

# --- 阈值设置 ---
# 身体弯曲角度阈值 (耳-肩-髋 夹角)
# 正常坐直约 160-175度，小于 145度 判定为驼背
POSTURE_ANGLE_THRESHOLD = 145 

# 颈部前伸比例阈值
NECK_OFFSET_THRESHOLD = 0.15 

# --- 优化参数 ---
# 1. 平滑系数 (0.1 ~ 1.0)
# 数值越小越平滑(抗抖动)，但延迟越高。0.3 是个平衡点
SMOOTH_FACTOR = 0.3 

# 2. 报警延迟 (防误报)
# 假设FPS为10，设置20帧意味着持续不良姿势 2秒 后才报警
ALARM_TRIGGER_FRAMES = 20 

# 久坐报警时间 (秒)
# 测试用 15秒，正式使用建议 45*60
SEDENTARY_LIMIT = 15 

# ==================== 2. 初始化 ====================
app = Flask(__name__)
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='threading')

mp_pose = mp.solutions.pose
mp_drawing = mp.solutions.drawing_utils

# 全局系统状态
system_state = {
    "sit_start_time": 0,
    "is_sitting": False,
    "duration": 0
}
state_lock = threading.Lock()

# 滤波历史数据 (用于平滑算法)
filter_history = {
    "smooth_angle": 170.0, # 初始设为完美角度
    "smooth_neck": 0.0
}

# ==================== 3. 核心算法函数 ====================

def calculate_3_point_angle(a, b, c):
    """
    计算三点夹角 (B为顶点)
    """
    a = np.array(a) # 耳
    b = np.array(b) # 肩
    c = np.array(c) # 髋

    ba = a - b
    bc = c - b

    # 计算余弦相似度
    cosine_angle = np.dot(ba, bc) / (np.linalg.norm(ba) * np.linalg.norm(bc) + 1e-6)
    cosine_angle = np.clip(cosine_angle, -1.0, 1.0)
    angle = np.arccos(cosine_angle)
    return np.degrees(angle)

def analyze_posture_smooth(landmarks, w, h):
    """
    带平滑滤波的分析逻辑
    """
    global filter_history
    
    # 获取【右侧】关键点 (8:右耳, 12:右肩, 24:右髋)
    # 如果要改左侧，请用: 7, 11, 23
    ear = [landmarks[8].x * w, landmarks[8].y * h]
    shoulder = [landmarks[12].x * w, landmarks[12].y * h]
    hip = [landmarks[24].x * w, landmarks[24].y * h]

    # 1. 计算当前帧的原始值
    raw_angle = calculate_3_point_angle(ear, shoulder, hip)
    
    # 计算颈部水平偏移 (假设脸朝右：耳X > 肩X)
    # 如果脸朝左，请改为 (shoulder[0] - ear[0])
    raw_neck = (ear[0] - shoulder[0]) / w 

    # 2. 执行 EMA 平滑滤波
    # 新平滑值 = α * 当前值 + (1-α) * 历史值
    smooth_angle = (SMOOTH_FACTOR * raw_angle) + ((1 - SMOOTH_FACTOR) * filter_history["smooth_angle"])
    smooth_neck = (SMOOTH_FACTOR * raw_neck) + ((1 - SMOOTH_FACTOR) * filter_history["smooth_neck"])
    
    # 更新历史
    filter_history["smooth_angle"] = smooth_angle
    filter_history["smooth_neck"] = smooth_neck

    # 3. 判定逻辑 (使用平滑后的值)
    text = "Good"
    color = (0, 255, 0) # 绿
    is_bad = False
    
    # 调试打印 (建议在调节阈值时打开)
    # print(f"Angle: {int(smooth_angle)} | Neck: {smooth_neck:.2f}")

    if smooth_angle < POSTURE_ANGLE_THRESHOLD:
        text = f"Hunchback ({int(smooth_angle)})"
        color = (0, 0, 255) # 红
        is_bad = True
    elif smooth_neck > NECK_OFFSET_THRESHOLD:
        text = "Neck Forward"
        color = (0, 165, 255) # 橙
        is_bad = True
    else:
        text = f"Good ({int(smooth_angle)})"
        color = (0, 255, 0) # 绿
        is_bad = False

    return text, color, is_bad

# ==================== 4. 主循环 ====================
def start_ai_camera_loop():
    print(f"[系统] AI 引擎启动 (精度优化版)...")
    
    # 使用 model_complexity=1 (Full) 以获得更高精度 (如果树莓派太卡改回0)
    pose = mp_pose.Pose(min_detection_confidence=0.5, min_tracking_confidence=0.5, model_complexity=1)
    
    cap = cv2.VideoCapture(0)
    cap.set(3, 640)
    cap.set(4, 480)

    # 状态计数器
    missing_person_frames = 0 
    bad_posture_frames = 0  # 记录不良姿势持续了多少帧

    while True:
        try:
            ret, frame = cap.read()
            if not ret:
                time.sleep(1)
                continue

            # 处理图像
            image = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            image.flags.writeable = False
            results = pose.process(image)
            image.flags.writeable = True
            image = cv2.cvtColor(image, cv2.COLOR_RGB2BGR)

            # 默认状态
            visual_text = "No Person"
            status_color = (200, 200, 200)
            is_bad_final = False
            has_person = False

            if results.pose_landmarks:
                has_person = True
                missing_person_frames = 0
                
                # 绘制骨架
                mp_drawing.draw_landmarks(image, results.pose_landmarks, mp_pose.POSE_CONNECTIONS)
                
                # === 调用平滑分析逻辑 ===
                h, w, _ = frame.shape
                temp_text, temp_color, is_bad_frame = analyze_posture_smooth(results.pose_landmarks.landmark, w, h)
                
                # === 防抖动逻辑 (迟滞策略) ===
                if is_bad_frame:
                    bad_posture_frames += 1
                else:
                    # 如果姿势恢复正常，计数器快速递减(而不是直接归零)，防止临界值闪烁
                    bad_posture_frames = max(0, bad_posture_frames - 2)
                
                # 只有累计的不良帧数超过阈值，才真正报警
                if bad_posture_frames > ALARM_TRIGGER_FRAMES:
                    visual_text = temp_text
                    status_color = temp_color
                    is_bad_final = True
                else:
                    # 虽然这一帧不好，但还没达到报警时间，显示正常
                    visual_text = f"Good ({int(filter_history['smooth_angle'])})"
                    status_color = (0, 255, 0)
                    is_bad_final = False
                
            else:
                missing_person_frames += 1
                # 没人时，也重置不良计数
                bad_posture_frames = 0

            # === 计时与久坐逻辑 ===
            with state_lock:
                current_time = time.time()
                if has_person:
                    if not system_state["is_sitting"]:
                        system_state["sit_start_time"] = current_time
                        system_state["is_sitting"] = True
                    system_state["duration"] = int(current_time - system_state["sit_start_time"])
                elif missing_person_frames > 5:
                    system_state["is_sitting"] = False
                    system_state["duration"] = 0
                    visual_text = "User Away"

                # 久坐判定优先级最高
                if system_state["duration"] > SEDENTARY_LIMIT:
                    visual_text = "Time to Stand up!"
                    status_color = (0, 0, 255)
                    is_bad_final = True

            # === 模拟压力数据 ===
            fake_pressure = [0.25, 0.25, 0.25, 0.25] if system_state["is_sitting"] else [0.0, 0.0, 0.0, 0.0]

            # === 桌面显示 ===
            cv2.putText(image, visual_text, (10, 40), cv2.FONT_HERSHEY_SIMPLEX, 0.8, status_color, 2)
            cv2.putText(image, f"Time: {system_state['duration']}s", (10, 80), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 0), 2)
            
            cv2.imshow('Smart Posture (Pro Algo)', image)

            # === 发送数据 ===
            payload = {
                "posture_text": visual_text,
                "is_bad": is_bad_final,
                "sit_time": system_state["duration"],
                "pressure_data": fake_pressure
            }
            socketio.emit('server_update', payload)
            
            if cv2.waitKey(1) & 0xFF == ord('q'):
                break
            socketio.sleep(0.01)

        except Exception as e:
            print(f"Loop Error: {e}")
            time.sleep(1)

    cap.release()
    cv2.destroyAllWindows()

if __name__ == '__main__':
    server_thread = threading.Thread(target=lambda: socketio.run(app, host=HOST_IP, port=PORT))
    server_thread.daemon = True 
    server_thread.start()
    print(f"[系统] 服务器运行在: http://{HOST_IP}:{PORT}")
    
    start_ai_camera_loop()