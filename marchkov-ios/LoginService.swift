import Foundation

struct LoginService {
    static let shared = LoginService()
    private init() {}
    
    private var token: String?
    private let session = URLSession.shared
    
    struct LoginResponse: Codable {
        let success: Bool
        let token: String?
    }
    
    struct BusInfo: Codable {
        let timeId: Int
        let yaxis: String
        let date: String
        let margin: Int
        
        enum CodingKeys: String, CodingKey {
            case timeId = "time_id"
            case yaxis
            case date
            case row
        }
        
        enum RowKeys: String, CodingKey {
            case margin
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            timeId = try container.decode(Int.self, forKey: .timeId)
            yaxis = try container.decode(String.self, forKey: .yaxis)
            date = try container.decode(String.self, forKey: .date)
            
            let rowContainer = try container.nestedContainer(keyedBy: RowKeys.self, forKey: .row)
            margin = try rowContainer.decode(Int.self, forKey: .margin)
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(timeId, forKey: .timeId)
            try container.encode(yaxis, forKey: .yaxis)
            try container.encode(date, forKey: .date)
            
            var rowContainer = container.nestedContainer(keyedBy: RowKeys.self, forKey: .row)
            try rowContainer.encode(margin, forKey: .margin)
        }
    }
    
    struct Resource: Codable {
        let id: Int
        let name: String
        let busInfos: [BusInfo]
        
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case table
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            
            let tableContainer = try container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .table)
            let tableKey = tableContainer.allKeys.first!
            busInfos = try tableContainer.decode([BusInfo].self, forKey: tableKey)
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            
            var tableContainer = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .table)
            try tableContainer.encode(busInfos, forKey: AnyCodingKey(stringValue: "1")!)
        }
    }
    
    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        
        init?(stringValue: String) {
            self.stringValue = stringValue
        }
        
        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = String(intValue)
        }
    }
    
    func login(username: String, password: String, completion: @escaping (Result<LoginResponse, Error>) -> Void) {
        LogManager.shared.addLog("开始登录")
        let url = URL(string: "https://iaaa.pku.edu.cn/iaaa/oauthlogin.do")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyData = "appid=wproc&userName=\(username)&password=\(password)&redirUrl=https://wproc.pku.edu.cn/site/login/cas-login?redirect_url=https://wproc.pku.edu.cn/v2/reserve/"
        request.httpBody = bodyData.data(using: .utf8)
        
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                LogManager.shared.addLog("登录失败：\(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                let error = NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                completion(.failure(error))
                return
            }
            
            do {
                let loginResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
                LogManager.shared.addLog("登录响应解码成功")
                if loginResponse.success {
                    LogManager.shared.addLog("登录成功")
                    UserDataManager.shared.saveUserCredentials(username: username, password: password)
                } else {
                    LogManager.shared.addLog("登录失败：响应表示失败")
                }
                completion(.success(loginResponse))
            } catch {
                LogManager.shared.addLog("登录响应解码失败：\(error.localizedDescription)")
                completion(.failure(error))
            }
        }
        
        task.resume()
    }
    
    func getResources(token: String, completion: @escaping (Result<[Resource], Error>) -> Void) {
        LogManager.shared.addLog("开始获取资源")
        // Step 1: Follow redirect with token
        let redirectURL = URL(string: "https://wproc.pku.edu.cn/site/login/cas-login?redirect_url=https://wproc.pku.edu.cn/v2/reserve/&_rand=0.6441813796046802&token=\(token)")!
        
        LogManager.shared.addLog("Step 1: 发送重定向请求 - URL: \(redirectURL.absoluteString)")
        let task1 = session.dataTask(with: redirectURL) { _, response, error in
            if let error = error {
                LogManager.shared.addLog("Step 1 失败: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                LogManager.shared.addLog("Step 1 成功: 状态码 \(httpResponse.statusCode)")
            }
            
            // Step 2: Get resources
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let date = dateFormatter.string(from: Date())
            let resourcesURL = URL(string: "https://wproc.pku.edu.cn/site/reservation/list-page?hall_id=1&time=\(date)&p=1&page_size=0")!
            
            LogManager.shared.addLog("Step 2: 获取资源 - URL: \(resourcesURL.absoluteString)")
            let task2 = self.session.dataTask(with: resourcesURL) { data, response, error in
                if let error = error {
                    LogManager.shared.addLog("Step 2 失败: \(error.localizedDescription)")
                    completion(.failure(error))
                    return
                }
                
                guard let data = data else {
                    let error = NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])
                    LogManager.shared.addLog("Step 2 失败: 未收到数据")
                    completion(.failure(error))
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    LogManager.shared.addLog("Step 2 成功: 状态码 \(httpResponse.statusCode)")
                }
                
                do {
                    let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
                    
                    let listData = try JSONSerialization.data(withJSONObject: (json?["d"] as? [String: Any])?["list"] ?? [], options: [])
                    let resources = try JSONDecoder().decode([Resource].self, from: listData)
                    LogManager.shared.addLog("成功解析资源: 共\(resources.count)个资源")
                    completion(.success(resources))
                } catch {
                    LogManager.shared.addLog("解析资源失败: \(error.localizedDescription)")
                    completion(.failure(error))
                }
            }
            task2.resume()
        }
        task1.resume()
    }
    
    func getReservationResult(resources: [Resource], completion: @escaping (Result<ReservationResult, Error>) -> Void) {
        LogManager.shared.addLog("开始获取预约结果")
        let userDefaults = UserDefaults.standard
        let criticalTime = userDefaults.integer(forKey: "criticalTime")
        let flagMorningToYanyuan = userDefaults.bool(forKey: "flagMorningToYanyuan")
        let prevInterval = userDefaults.integer(forKey: "prevInterval")
        let nextInterval = userDefaults.integer(forKey: "nextInterval")
        
        LogManager.shared.addLog("设置参数: 临界时间 = \(criticalTime), 早上去燕园 = \(flagMorningToYanyuan), 过期班车追溯 = \(prevInterval), 未来班车预约 = \(nextInterval)")
        
        let currentDate = Date()
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: currentDate)
        
        let direction: BusDirection
        if currentHour < criticalTime {
            direction = flagMorningToYanyuan ? .toYanyuan : .toChangping
        } else {
            direction = flagMorningToYanyuan ? .toChangping : .toYanyuan
        }
        
        LogManager.shared.addLog("当前时间: \(currentHour):00, 班车方向: \(direction == .toYanyuan ? "去燕园" : "去昌平")")
        
        let filteredResources = resources.filter { resource in
            let resourceId = resource.id
            return (direction == .toYanyuan && (resourceId == 2 || resourceId == 4)) ||
            (direction == .toChangping && (resourceId == 5 || resourceId == 6 || resourceId == 7))
        }
        
        LogManager.shared.addLog("筛选后的资源数量: \(filteredResources.count)")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: currentDate)
        
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let currentTime = timeFormatter.string(from: currentDate)
        
        LogManager.shared.addLog("当前日期: \(today), 当前时间: \(currentTime)")
        
        for resource in filteredResources {
            LogManager.shared.addLog("检查资源: ID = \(resource.id), 名称 = \(resource.name)")
            for busInfo in resource.busInfos {
                LogManager.shared.addLog("检查班车信息: 日期 = \(busInfo.date), 时间 = \(busInfo.yaxis), 余票 = \(busInfo.margin)")
                if busInfo.date == today && busInfo.margin > 0 {
                    let busTime = busInfo.yaxis
                    if let timeDifference = getTimeDifference(currentTime: currentTime, busTime: busTime) {
                        LogManager.shared.addLog("时间差: \(timeDifference) 分钟")
                        if timeDifference >= -prevInterval && timeDifference <= nextInterval {
                            if timeDifference < 0 {
                                // Past bus
                                LogManager.shared.addLog("找到过期班车, 获取临时码")
                                getTempCode(resourceId: resource.id, startTime: busTime) { result in
                                    switch result {
                                    case .success(let qrCode):
                                        LogManager.shared.addLog("成功获取临时码")
                                        let reservationResult = ReservationResult(isPastBus: true, name: resource.name, yaxis: busTime, qrCode: qrCode)
                                        completion(.success(reservationResult))
                                    case .failure(let error):
                                        LogManager.shared.addLog("获取临时码失败: \(error.localizedDescription)")
                                        completion(.failure(error))
                                    }
                                }
                            } else {
                                // Future bus
                                LogManager.shared.addLog("找到未来班车, 开始预约")
                                reserveBus(resourceId: resource.id, date: today, timeId: busInfo.timeId) { result in
                                    switch result {
                                    case .success(let qrCode):
                                        LogManager.shared.addLog("预约成功")
                                        let reservationResult = ReservationResult(isPastBus: false, name: resource.name, yaxis: busTime, qrCode: qrCode)
                                        completion(.success(reservationResult))
                                    case .failure(let error):
                                        LogManager.shared.addLog("预约失败: \(error.localizedDescription)")
                                        completion(.failure(error))
                                    }
                                }
                            }
                            return
                        }
                    }
                }
            }
        }
        
        LogManager.shared.addLog("未找到合适的班车")
        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No suitable bus found"])))
    }
    
    private func getTimeDifference(currentTime: String, busTime: String) -> Int? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        
        guard let current = formatter.date(from: currentTime),
              let bus = formatter.date(from: busTime) else {
            return nil
        }
        
        let difference = bus.timeIntervalSince(current) / 60
        return Int(difference)
    }
    
    private func getTempCode(resourceId: Int, startTime: String, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://wproc.pku.edu.cn/site/reservation/get-sign-qrcode?type=1&resource_id=\(resourceId)&text=\(startTime)")!
        
        LogManager.shared.addLog("获取临时码 - URL: \(url.absoluteString)")
        
        session.dataTask(with: url) { data, response, error in
            if let error = error {
                LogManager.shared.addLog("获取临时码失败: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                LogManager.shared.addLog("获取临时码 - 状态码: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                LogManager.shared.addLog("获取临时码 - 未收到数据")
                completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    LogManager.shared.addLog("获取临时码 - 收到的JSON数据: \(json)")
                    if let d = json["d"] as? [String: Any],
                       let code = d["code"] as? String {
                        LogManager.shared.addLog("获取临时码成功: \(code)")
                        completion(.success(code))
                    } else {
                        LogManager.shared.addLog("获取临时码 - 无效的响应格式")
                        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])))
                    }
                }
            } catch {
                LogManager.shared.addLog("获取临时码 - JSON解析失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func reserveBus(resourceId: Int, date: String, timeId: Int, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://wproc.pku.edu.cn/site/reservation/launch")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyData = "resource_id=\(resourceId)&data=[{\"date\": \"\(date)\", \"period\": \(timeId), \"sub_resource_id\": 0}]"
        request.httpBody = bodyData.data(using: .utf8)
        
        LogManager.shared.addLog("预约班车 - URL: \(url.absoluteString)")
        LogManager.shared.addLog("预约班车 - 请求体: \(bodyData)")
        
        session.dataTask(with: request) { data, response, error in
            if let error = error {
                LogManager.shared.addLog("预约班车失败: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                LogManager.shared.addLog("预约班车 - 状态码: \(httpResponse.statusCode)")
            }
            
            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                LogManager.shared.addLog("预约班车 - 响应内容: \(responseString)")
            }
            
            LogManager.shared.addLog("预约班车成功,开始获取预约二维码")
            self.getReservationQRCode(resourceId: resourceId, date: date, yaxis: "") { result in
                completion(result)
            }
        }.resume()
    }
    
    private func getReservationQRCode(resourceId: Int, date: String, yaxis: String, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://wproc.pku.edu.cn/site/reservation/my-list-time?p=1&page_size=10&status=2&sort_time=true&sort=asc")!
        
        LogManager.shared.addLog("获取预约二维码 - URL: \(url.absoluteString)")
        
        session.dataTask(with: url) { data, response, error in
            if let error = error {
                LogManager.shared.addLog("获取预约二维码失败: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                LogManager.shared.addLog("获取预约二维码 - 状态码: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                LogManager.shared.addLog("获取预约二维码 - 未收到数据")
                completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    LogManager.shared.addLog("获取预约二维码 - 收到的JSON数据: \(json)")
                    if let d = json["d"] as? [String: Any],
                       let apps = d["data"] as? [[String: Any]] {
                        
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yyyy-MM-dd"
                        let today = dateFormatter.string(from: Date())
                        
                        for app in apps {
                            if let appResourceId = app["resource_id"] as? Int,
                               let appTime = app["appointment_time"] as? String,
                               let appId = app["id"] as? Int,
                               let appAppointmentId = app["hall_appointment_data_id"] as? Int,
                               appResourceId == resourceId,
                               appTime.starts(with: "\(today) \(yaxis)") {
                                
                                LogManager.shared.addLog("找到匹配的预约: ID = \(appId), AppointmentID = \(appAppointmentId)")
                                self.getQRCode(appId: appId, appAppointmentId: appAppointmentId) { result in
                                    completion(result)
                                }
                                return
                            }
                        }
                        
                        LogManager.shared.addLog("未找到匹配的预约")
                        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No matching reservation found"])))
                    } else {
                        LogManager.shared.addLog("获取预约二维码 - 无效的响应格式")
                        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])))
                    }
                }
            } catch {
                LogManager.shared.addLog("获取预约二维码 - JSON解析失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func getQRCode(appId: Int, appAppointmentId: Int, completion: @escaping (Result<String, Error>) -> Void) {
        let url = URL(string: "https://wproc.pku.edu.cn/site/reservation/get-sign-qrcode?id=\(appId)&type=0&hall_appointment_data_id=\(appAppointmentId)")!
        
        LogManager.shared.addLog("获取二维码 - URL: \(url.absoluteString)")
        
        session.dataTask(with: url) { data, response, error in
            if let error = error {
                LogManager.shared.addLog("获取二维码失败: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                LogManager.shared.addLog("获取二维码 - 状态码: \(httpResponse.statusCode)")
            }
            
            guard let data = data else {
                LogManager.shared.addLog("获取二维码 - 未收到数据")
                completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    LogManager.shared.addLog("获取二维码 - 收到的JSON数据: \(json)")
                    if let d = json["d"] as? [String: Any],
                       let code = d["code"] as? String {
                        LogManager.shared.addLog("获取二维码成功: \(code)")
                        completion(.success(code))
                    } else {
                        LogManager.shared.addLog("获取二维码 - 无效的响应格式")
                        completion(.failure(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])))
                    }
                }
            } catch {
                LogManager.shared.addLog("获取二维码 - JSON解析失败: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }.resume()
    }
}