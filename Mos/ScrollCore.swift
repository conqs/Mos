//
//  scrollSmooth.swift
//  Mos
//  滚动事件截取与判断核心类
//  Created by Cb on 2017/1/14.
//  Copyright © 2017年 Cb. All rights reserved.
//

import Cocoa

class ScrollCore: NSObject {
    
    // 总开关
    static var mainSwitch = true
    
    // 语言相关
    static let sysLang = NSLocale.preferredLanguages[0]
    static let cnLangs = ["zh-Hant-CN", "zh-Hant-HK", "zh-Hant-TW", "zh-Hans-CN", "zh-Hans-HK", "zh-Hans-TW", "zh-Hant-MO"]
    static let appLanguageIsCN = ScrollCore.cnLangs.contains(ScrollCore.sysLang) //判断是否中文语系
    
    // 全局设置相关
    static let defOption = ( smooth: true, reverse: true, autoLaunch: false )
    static let defAdvancedOption = ( speed: 0.95, time: 480, peak: 0.20 )
    static var option = ( smooth: true, reverse: true, autoLaunch: false )
    static var advancedOption = ( speed: 0.95, time: 480, peak: 0.20 )
    static var ignoreList = ( smooth: [String](), reverse: [String]() )
    static var whiteListMode = false
    
    // 延迟执行相关
    static var delayTimer:Timer!
    static var delayGap = 0.010 // 延迟时间(ms)
    
    // 处理鼠标事件的方向
    static var handleScrollType = ScrollCore.mousePos.Y
    static let mousePos = ( Y: UInt32(1), X: UInt32(1), YX: UInt32(2), YXZ: UInt32(3) )
    
    // 事件发送器相关
    static var scrollEventPosterStopCount = ( Y: 0, X: 0 )
    static var scrollEventPoster:CVDisplayLink?
    
    // 区分目标窗口相关
    static var lastEventTargetPID:pid_t = 1
    static var eventTargetPID:pid_t = 1
    static var eventTargetBundleId:String!
    static var ignoredApplications = [IgnoredApplication]()
    
    // 区分新滚动事件相关
    static var pulseGap = 0.3 // 间隔时间(s)
    static var pulseTimeCache: NSDate? //用于缓存上一次的时间
    
    // 滚动数据
    static var beforeLastScrollRef = ( Y: 0.0, X: 0.0 )
    static var lastScrollRef = ( Y: 0.0, X: 0.0 )
    static var scrollRef = ( Y: 0.0, X: 0.0 )
    static var autoScrollRef = ( Y: 0.0, X: 0.0 ) // 缓动生成的滚动信息
    static var singleScrollCount =  ( Y: 0, X: 0 ) // 单次滚动计数
    
    // 曲线数据相关
    static var headPulseScale = 4.0
    static var headPulseNormalize = 1.032
    static var tailPulseScale = 4.0
    static var tailPulseNormalize = 1.032
    // 动画相关
    static var fps = 60.0 // 帧数
    static var animTime = 380.0 // 动画时间 (这里已经由全局设置内的 '时间' 代替)
    static var turningScale = 0.20 // 转折位置 (这里已经由全局设置内的 '峰值位置' 代替)
    static var scrollScale = 0.95 // 放大系数 (这里已经由全局设置内的 '速度' 代替)
    static var totalPoint = Int(ScrollCore.fps * Double(ScrollCore.advancedOption.time) / 1000.0)
    static var turningPoint = Int(round(Double(ScrollCore.totalPoint)*ScrollCore.advancedOption.peak))
    
    // 初始化缓动曲线
    static var basePluseData = ScrollCore.initPluseData()
    static var realPluseData = ( Y: [Double](), X: [Double]() )
    
    

    static func becomeActive(notification:NSNotification){
        print("becomeActive")
    }
    
    static func resignActive(notification:NSNotification){
        print("resignActive")
    }
    
    // eventTap相关
    static var eventTap:CFMachPort?
    static let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    static let eventCallBack: CGEventTapCallBack = {
        (proxy, type, event, refcon) in
        
        // 是否返回原始事件
        var handbackOriginalEvent = true
        
        // 判断输入源 (无法区分黑苹果, 因为黑苹果的触控板驱动是模拟鼠标输入的)
        if ScrollCore.isTouchPad(of: event) {
            // 当触控板输入
            // 啥都不干
        } else {
            // 当鼠标输入, 根据需要执行翻转方向/平滑滚动
            
            // 获取光标当前窗口信息, 用于在某些窗口中禁用, 更新每次的PID
            ScrollCore.lastEventTargetPID = ScrollCore.eventTargetPID
            ScrollCore.eventTargetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            // 如果目标PID有变化, 则重新获取一次窗口名字, 更新到 ScrollCore.eventTargetName 里面
            if ScrollCore.lastEventTargetPID != ScrollCore.eventTargetPID {
                if let applicationBundleId = ScrollCore.getApplicationBundleIdFrom(pid: ScrollCore.eventTargetPID) {
                    ScrollCore.eventTargetBundleId = applicationBundleId
                }
            }
            
            // 获取列表中应用程序的设置信息
            let ignoredApplicaton = ScrollCore.applicationInIgnoreListOf(bundleId: ScrollCore.eventTargetBundleId)
            // 是否翻转
            let enableReverse = ScrollCore.enableReverse(ignoredApplicaton: ignoredApplicaton)
            // 是否平滑
            let enableSmooth = ScrollCore.enableSmooth(ignoredApplicaton: ignoredApplicaton)
            
            // 格式化滚动数据
            var scrollFixY = Int64(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            var scrollFixX = Int64(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            var scrollPtY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            var scrollPtX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            var scrollFixPtY = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            var scrollFixPtX = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            
            // 处理事件
            var scrollValue = ( Y: 0.0, X: 0.0 )
            // Y轴
            if var scrollY = ScrollCore.axisDataIsExistIn(scrollFixY, scrollPtY, scrollFixPtY) {
                // 是否翻转滚动
                if enableReverse {
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -scrollFixY)
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: -scrollPtY)
                    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -scrollFixPtY)
                    scrollY.data = -scrollY.data
                }
                // 是否平滑滚动
                if enableSmooth {
                    // 禁止返回原始事件
                    handbackOriginalEvent = false
                    // 如果输入值为Fixed型则不处理; 如果为非Fixed类型且小于10则归一化为10
                    if scrollY.isFixed {
                        scrollValue.Y = scrollY.data
                    } else {
                        let absY = abs(scrollY.data)
                        if absY > 0.0 && absY < 10.0 {
                            scrollValue.Y = scrollY.data<0.0 ? -10.0 : 10.0
                        } else {
                            scrollValue.Y = scrollY.data
                        }
                    }
                }
            }
            // X轴
            if var scrollX = ScrollCore.axisDataIsExistIn(scrollFixX, scrollPtX, scrollFixPtX) {
                // 是否翻转滚动
                if ScrollCore.enableReverse(ignoredApplicaton: ignoredApplicaton) {
                    event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -scrollFixX)
                    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -scrollPtX)
                    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -scrollFixPtX)
                    scrollX.data = -scrollX.data
                }
                // 是否平滑滚动
                if ScrollCore.enableSmooth(ignoredApplicaton: ignoredApplicaton) {
                    // 禁止返回原始事件
                    handbackOriginalEvent = false
                    // 如果输入值为Fixed型则不处理; 如果为非Fixed类型且小于10则归一化为10
                    if scrollX.isFixed {
                        scrollValue.X = scrollX.data
                    } else {
                        let absX = abs(scrollX.data)
                        if absX > 0.0 && absX < 10.0 {
                            scrollValue.X = scrollX.data<0.0 ? -10.0 : 10.0
                        } else {
                            scrollValue.X = scrollX.data
                        }
                    }
                }
            }
            // 启动一下事件
            if (scrollValue.Y != 0.0 || scrollValue.X != 0.0) {
                ScrollCore.updateScrollData(Y: scrollValue.Y, X: scrollValue.X)
                ScrollCore.activeScrollEventPoster()
            }
        }
        
        // 返回事件对象
        if handbackOriginalEvent {
            return Unmanaged.passRetained(event)
        } else {
            return nil
        }
    }
    
    // 启动应用
    static func startHandling() {
        // 读取用户保存设置
        ScrollCore.readPreferencesData()
        // 开始截取事件
        ScrollCore.eventTap = ScrollCore.startCapture(event: ScrollCore.mask, to: ScrollCore.eventCallBack, at: .cghidEventTap, where: .tailAppendEventTap, for: .defaultTap)
        // 初始化事件发送器
        ScrollCore.initScrollEventPoster()
    }
    
    // 停止应用
    static func endHandling() {
        // 停止截取事件
        ScrollCore.stopCapture(tap: ScrollCore.eventTap)
        // 停止事件发送器
        ScrollCore.stopScrollEventPoster()
    }
    
    // 开始截取事件
    static func startCapture(event mask: CGEventMask, to eventHandler: @escaping CGEventTapCallBack, at eventTap: CGEventTapLocation, where eventPlace: CGEventTapPlacement, for behaver: CGEventTapOptions) -> CFMachPort {
        guard let eventTap = CGEvent.tapCreate(tap: eventTap, place: eventPlace, options: behaver, eventsOfInterest: mask, callback: eventHandler, userInfo: nil) else {
            fatalError("Failed to create event tap")
        }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return eventTap
    }
    // 停止截取事件
    static func stopCapture(tap: CFMachPort?) {
        if let eventTap = tap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        } else {
            fatalError("Failed to disable eventTap")
        }
    }
    
    
    
    // 延迟执行
    static func delayPreScroll() {
        if ScrollCore.delayTimer !== nil {
            ScrollCore.delayTimer.invalidate()
        }
        ScrollCore.delayTimer = Timer.scheduledTimer(timeInterval: ScrollCore.delayGap, target:ScrollCore.self, selector: #selector(ScrollCore.activeScrollEventPoster), userInfo:nil, repeats:false)
    }
    
    
    
    // 事件发送器 (CVDisplayLink)
    static func initScrollEventPoster() {
        // 新建一个CVDisplayLinkSetOutputCallback来执行循环
        CVDisplayLinkCreateWithActiveCGDisplays(&ScrollCore.scrollEventPoster)
        CVDisplayLinkSetOutputCallback(ScrollCore.scrollEventPoster!, {
            (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
            // 处理Y轴事件
            ScrollCore.handleScroll()
            return kCVReturnSuccess
        }, nil)
    }
    @objc static func activeScrollEventPoster() {
        ScrollCore.updateRealPluseData(Y: ScrollCore.scrollRef.Y, X: ScrollCore.scrollRef.X)
        // 如果事件发送器没有在运行, 就运行一下
        if !CVDisplayLinkIsRunning(ScrollCore.scrollEventPoster!) {
            CVDisplayLinkStart(ScrollCore.scrollEventPoster!)
        } else {
            // 如果已经在运行, 则重设一下计数器
            ScrollCore.scrollEventPosterStopCount = ( Y: 0, X: 0 )
        }
    }
    static func stopScrollEventPoster() {
        if let poster = ScrollCore.scrollEventPoster {
            CVDisplayLinkStop(poster)
        }
    }

    
    // 更新滚动数据
    static func updateScrollData(Y: Double, X: Double) {
        ScrollCore.beforeLastScrollRef = ScrollCore.lastScrollRef
        ScrollCore.lastScrollRef = ScrollCore.scrollRef
        ScrollCore.scrollRef.Y = Y
        ScrollCore.scrollRef.X = X
    }
    // 更新实际滚动曲线
    static func updateRealPluseData(Y: Double, X: Double) {
        // TODO: 处理X轴数据
        var realPluseDataY = [Double]()
        var realPluseDataX = [Double]()
        for i in ScrollCore.basePluseData {
            realPluseDataY.append(i*Y)
            realPluseDataX.append(i*X)
        }
        ScrollCore.realPluseData.Y = realPluseDataY
        ScrollCore.realPluseData.X = realPluseDataX
    }
    
    
    
    // 判断是否触控板事件
    static func isTouchPad(of event: CGEvent) -> Bool {
        // MomentumPhase 或 ScrollPhase任一不为零, 则为触控板
        if (event.getDoubleValueField(.scrollWheelEventMomentumPhase) != 0.0) || (event.getDoubleValueField(.scrollWheelEventScrollPhase) != 0.0) {
            return true
        }
        // 累计加速度
        if event.getDoubleValueField(.scrollWheelEventScrollCount) != 0.0 {
            return true
        }
        return false
    }
    
    
    
    // 判断是否新的滚动事件
    static func isNewScroll(of event: CGEvent) -> Bool {
        // 重设时间戳
        func updatePulseTime() {
            ScrollCore.pulseTimeCache = NSDate()
        }
        
        // 如果scrollWheelEventScrollCount字段存在, 则为触控板继续加速运动, 非新滚动
        if event.getDoubleValueField(.scrollWheelEventScrollCount) != 0.0 {
            updatePulseTime()
            return false
        }
        // 如果pulseTimeCache存在
        let nowTime = NSDate()
        if let pulseTimeCache = ScrollCore.pulseTimeCache {
            updatePulseTime()
            if nowTime.timeIntervalSince(pulseTimeCache as Date) > ScrollCore.pulseGap {
                // pulseTimeCache存在, 且大于pulseGap, 则判定为新滚动
                return true
            } else {
                // pulseTimeCache存在, 但小于pulseGap, 则判定为非新滚动
                return false
            }
        } else {
            // 如果pulseTimeCache不存在, 则是第一次滚动, 判定为新滚动
            updatePulseTime()
            return true
        }
    }
    
    
    
    // 判断指定的轴数据是否存在, 作为处理判断依据
    static func axisDataIsExistIn(_ scrollFix: Int64, _ scrollPt: Double, _ scrollFixPt: Double) -> (data: Double, isFixed: Bool)? {
        if scrollPt != 0.0 {
            return (data: scrollPt, isFixed: false)
        }
        if scrollFixPt != 0.0 {
            return (data: scrollFixPt, isFixed: true)
        }
        if scrollFix != 0 {
            return (data: Double(scrollFix), isFixed: true)
        }
        return nil
    }
    
    

    // 主处理函数(CVDisplayLink)
    static func handleScroll() {
        // 如果 X, Y 轴均到达既定步数, 则停止事件
        if ScrollCore.scrollEventPosterStopCount.Y >= ScrollCore.totalPoint || ScrollCore.scrollEventPosterStopCount.X >= ScrollCore.totalPoint {
            ScrollCore.stopScrollEventPoster()
        }
        var scrollValue = ( X: Int32(0), Y: Int32(0) )
        // 处理 Y 轴事件
        if ScrollCore.scrollEventPosterStopCount.Y >= ScrollCore.totalPoint {
            // 如果 Y 轴均到达既定步数, 则清除临时变量
            ScrollCore.resetScrollValue(axis: "Y")
        } else {
            // 否则则截取ScrollRef内的值来发送
            scrollValue.Y = ScrollCore.scrollRef.Y != 0.0 ? ScrollCore.getScrollValue(axis: "Y") : 0
        }
        // 处理 X 轴事件
        if ScrollCore.scrollEventPosterStopCount.X >= ScrollCore.totalPoint {
            // 如果 X 轴均到达既定步数, 则清除临时变量
            ScrollCore.resetScrollValue(axis: "X")
        } else {
            // 否则则截取ScrollRef内的值来发送
            scrollValue.X = ScrollCore.scrollRef.X != 0.0 ? ScrollCore.getScrollValue(axis: "X") : 0
        }
        // 发送事件
        MouseEvent.scroll(ScrollCore.mousePos.YX, yScroll: scrollValue.Y, xScroll: scrollValue.X)
    }
    // 清除临时变量
    static func resetScrollValue(axis: String) {
        if axis == "Y" {
            ScrollCore.scrollEventPosterStopCount.Y = 0
            ScrollCore.singleScrollCount.Y = 0
            ScrollCore.autoScrollRef.Y = 0
        }
        if axis == "X" {
            ScrollCore.scrollEventPosterStopCount.X = 0
            ScrollCore.singleScrollCount.X = 0
            ScrollCore.autoScrollRef.X = 0
        }
    }
    static func getScrollValue(axis: String) -> Int32 {
        var value = Int32(0)
        if axis == "Y" {
            if ScrollCore.scrollEventPosterStopCount.Y == 0 {
                if ScrollCore.autoScrollRef.Y != 0 {
                    // 输入的滚动事件, 且不是第一次滚动, 则查找最接近的值来滚动
                    var startIndex = 0
                    if ScrollCore.singleScrollCount.Y >= ScrollCore.turningPoint {
                        // 如果单次滚动计数大于等于转折位置, 则直接取峰值
                        startIndex = ScrollCore.findPeakIndex(from: ScrollCore.realPluseData.Y)
                    } else {
                        // 否则从前面计数
                        startIndex = ScrollCore.findApproachMaxHeadValue(of: ScrollCore.autoScrollRef.Y, from: ScrollCore.realPluseData.Y)
                    }
                    value = Int32(ScrollCore.realPluseData.Y[startIndex])
                    ScrollCore.scrollEventPosterStopCount.Y = startIndex==0 ? 1 : startIndex // 避免一直在0循环
                    ScrollCore.singleScrollCount.Y += 1
                } else {
                    // 否则就按正常缓动的滚动事件, 按照正常递增
                    value = Int32(ScrollCore.realPluseData.Y[ScrollCore.scrollEventPosterStopCount.Y])
                    ScrollCore.autoScrollRef.Y = ScrollCore.realPluseData.Y[ScrollCore.scrollEventPosterStopCount.Y]
                    ScrollCore.scrollEventPosterStopCount.Y += 1
                }
            } else {
                // 缓动的滚动事件, 按照正常递增
                value = Int32(ScrollCore.realPluseData.Y[ScrollCore.scrollEventPosterStopCount.Y])
                ScrollCore.autoScrollRef.Y = ScrollCore.realPluseData.Y[ScrollCore.scrollEventPosterStopCount.Y]
                ScrollCore.scrollEventPosterStopCount.Y += 1
            }
        }
        if axis == "X" {
            if ScrollCore.scrollEventPosterStopCount.X == 0 {
                if ScrollCore.autoScrollRef.X != 0 {
                    // 输入的滚动事件, 且不是第一次滚动, 则查找最接近的值来滚动
                    var startIndex = 0
                    if ScrollCore.singleScrollCount.X >= ScrollCore.turningPoint {
                        // 如果单次滚动计数大于等于转折位置, 则直接取峰值
                        startIndex = ScrollCore.findPeakIndex(from: ScrollCore.realPluseData.X)
                    } else {
                        // 否则从前面计数
                        startIndex = ScrollCore.findApproachMaxHeadValue(of: ScrollCore.autoScrollRef.X, from: ScrollCore.realPluseData.X)
                    }
                    value = Int32(ScrollCore.realPluseData.X[startIndex])
                    ScrollCore.scrollEventPosterStopCount.X = startIndex==0 ? 1 : startIndex // 避免一直在0循环
                    ScrollCore.singleScrollCount.X += 1
                } else {
                    // 否则就按正常缓动的滚动事件, 按照正常递增
                    value = Int32(ScrollCore.realPluseData.X[ScrollCore.scrollEventPosterStopCount.X])
                    ScrollCore.autoScrollRef.X = ScrollCore.realPluseData.X[ScrollCore.scrollEventPosterStopCount.X]
                    ScrollCore.scrollEventPosterStopCount.X += 1
                }
            } else {
                // 缓动的滚动事件, 按照正常递增
                value = Int32(ScrollCore.realPluseData.X[ScrollCore.scrollEventPosterStopCount.X])
                ScrollCore.autoScrollRef.X = ScrollCore.realPluseData.X[ScrollCore.scrollEventPosterStopCount.X]
                ScrollCore.scrollEventPosterStopCount.X += 1
            }
        }
        return value
    }
    
    // 缓动曲线
    static func headPulse(pos: Double) -> Double {
        //  防止数据越界
        if pos >= 1.0 {
            return 1.0
        }
        if pos <= 0.0 {
            return 0.0
        }
        // 计算位置
        var val = 0.0, start = 0.0, expx = 0.0
        var x = pos * ScrollCore.headPulseScale;
        if (x < 1) {
            // 加速
            val = x - (1.0 - exp(-x));
        } else {
            // 减速
            start = exp(-1.0);
            x -= 1.0;
            expx = 1.0 - exp(-x);
            val = start + (expx * (1.0 - start));
        }
        return val*ScrollCore.headPulseNormalize
    }
    static func tailPulse(pos: Double) -> Double {
        //  防止数据越界
        if pos >= 1.0 {
            return 0.0
        }
        if pos <= 0.0 {
            return 1.0
        }
        // 计算位置
        var val = 0.0, start = 0.0, expx = 0.0
        var x = pos * ScrollCore.tailPulseScale;
        if (x < 1) {
            // 加速
            val = x - (1.0 - exp(-x));
        } else {
            // 减速
            start = exp(-1.0);
            x -= 1.0;
            expx = 1.0 - exp(-x);
            val = start + (expx * (1.0 - start));
        }
        return 1 - (val*ScrollCore.tailPulseNormalize)
    }
    // 根据设定的步数和曲线拟合成减速缓动数据
    static func initPluseData() -> [Double] {
        var pulseData = [Double]()
        var plusePoint:Double!
        var samplePoint:Double!
        var basePoint:Double!
        for i in 1...ScrollCore.totalPoint {
            let di = Double(i)
            let dTotalPoint = Double(ScrollCore.totalPoint)
            if (di <= dTotalPoint*ScrollCore.advancedOption.peak) {
                samplePoint = di
                basePoint = dTotalPoint*ScrollCore.advancedOption.peak
                plusePoint = ScrollCore.headPulse(pos: samplePoint/basePoint)
            } else {
                samplePoint = di - dTotalPoint*ScrollCore.advancedOption.peak
                basePoint = dTotalPoint*(1-ScrollCore.advancedOption.peak)
                plusePoint = ScrollCore.tailPulse(pos: samplePoint/basePoint)
            }
            pulseData.append(plusePoint * ScrollCore.advancedOption.speed)
        }
        return pulseData
    }
    // 查找数组中最接近输入值的项的Index
    static func findApproachValue(of value: Double, from array: [Double]) -> Int {
        for i in 1...array.count {
            let left = array[i-1]
            let right = array[i]
            if left/right<1 {
                // 右边大于左边, 上升期
                let leftDiff = value - left
                let rightDiff = value - right
                if leftDiff*rightDiff<=0 {
                    // 判断是给左值的还是右值
                    if abs(leftDiff) < abs(rightDiff) {
                        return i-1
                    } else {
                        return i
                    }
                }
            } else {
                // 左大于右, 减速, 直接返回最大值
                return i
            }
        }
        return 0
    }
    // 查找数组中最接近输入值中最大的的项的Index
    static func findApproachMaxHeadValue(of value: Double, from array: [Double]) -> Int {
        for i in 1...array.count {
            let left = array[i-1]
            let right = array[i]
            if left/right<1 {
                // 右边大于左边, 上升期
                let leftDiff = value - left
                let rightDiff = value - right
                if leftDiff*rightDiff<=0 {
                    return array.index(of: right)!
                }
            } else {
                // 左边大于右边, 开始下降, 直接返回最大值
                return i
            }
        }
        return 0
    }
    // 查找数组中最接近输入值中最大的的项位于下降区间的Index
    static func findApproachMaxTailValue(of value: Double, from array: [Double]) -> Int {
        let peakIndex = findPeakIndex(from: array)
        // 直接从峰值之后找
        for i in peakIndex..<array.count {
            let left = array[i-1]
            let right = array[i]
            
            let leftDiff = value - left
            let rightDiff = value - right
            if leftDiff*rightDiff<=0 {
                return array.index(of: left)!<peakIndex ? peakIndex : array.index(of: left)!-1
            }
        }
        // 找不到, 直接返回最大值
        return peakIndex
    }
    // 返回峰值的Index
    static func findPeakIndex(from array: [Double]) -> Int {
        if array[1] < 0 {
            // 正极数组, 返回最小值
            return array.index(of: array.min()!)!
        } else {
            // 正值数组, 返回最大值
            return array.index(of: array.max()!)!
        }
    }
    
    
    
    // 从UserDefaults中读取用户设置
    static func readPreferencesData() {
        if let smooth = UserDefaults.standard.string(forKey: "smooth") {
            ScrollCore.option.smooth = smooth=="true" ? true : false
        }
        if let reverse = UserDefaults.standard.string(forKey: "reverse") {
            ScrollCore.option.reverse = reverse=="true" ? true : false
        }
        if let autoLaunch = UserDefaults.standard.string(forKey: "autoLaunch") {
            ScrollCore.option.autoLaunch = autoLaunch=="true" ? true : false
        }
        if UserDefaults.standard.double(forKey: "speed") != 0.0 {
            ScrollCore.advancedOption.speed = UserDefaults.standard.double(forKey: "speed")
        }
        if UserDefaults.standard.integer(forKey: "time") != 0 {
            ScrollCore.advancedOption.time = UserDefaults.standard.integer(forKey: "time")
        }
        if UserDefaults.standard.double(forKey: "peak") != 0.0 {
            ScrollCore.advancedOption.peak = UserDefaults.standard.double(forKey: "peak")
        }
        if let whiteListMode = UserDefaults.standard.string(forKey: "whiteListMode") {
            ScrollCore.whiteListMode = whiteListMode=="true" ? true : false
        }
        if let archivedData = UserDefaults.standard.object(forKey: "ignoredApplications") {
            let ignoredApplications = NSKeyedUnarchiver.unarchiveObject(with: archivedData as! Data)
            ScrollCore.ignoredApplications = ignoredApplications as? [IgnoredApplication] ?? [IgnoredApplication]()
            ScrollCore.updateIgnoreList()
        }
    }
    
    
    // 更新ignoreList
    static func updateIgnoreList() {
        // 清空一下数据
        ScrollCore.ignoreList.smooth = [String]()
        ScrollCore.ignoreList.reverse = [String]()
        // 从ignoredApplications读到ignoreList
        for ignoredApplication in ScrollCore.ignoredApplications {
            if ignoredApplication.notSmooth {
                ScrollCore.ignoreList.smooth.append(ignoredApplication.bundleId)
            }
            if ignoredApplication.notReverse {
                ScrollCore.ignoreList.reverse.append(ignoredApplication.bundleId)
            }
        }
        // 保存设置
        let archivedData = NSKeyedArchiver.archivedData(withRootObject: ScrollCore.ignoredApplications)
        UserDefaults.standard.set(archivedData, forKey:"ignoredApplications")
    }
    
    
    
    // 从Pid获取进程名称
    static func getApplicationBundleIdFrom(pid: pid_t) -> String? {
        // 更新列表
        let runningApps = NSWorkspace.shared.runningApplications
        if let matchApp = runningApps.filter({$0.processIdentifier == pid}).first {
            // 如果找到bundleId则返回, 不然则判定为子进程, 通过查找其父进程Id, 递归查找其父进程的bundleId
            if let bundleId = matchApp.bundleIdentifier {
                return bundleId as String?
            } else {
                let ppid = ProcessUtils.getParentPid(from: matchApp.processIdentifier)
                return ppid==1 ? nil : ScrollCore.getApplicationBundleIdFrom(pid: ppid)
            }
        } else {
            return nil
        }
    }
    
    // 判断 LaunchPad 是否激活
    static var launchpadActiveCache = false
    static var launchpadLastDetectTime = 0.0
    static func launchpadIsActive() -> Bool {
        // 如果距离上次检测时间大于500ms, 则重新检测一遍, 否则直接返回上次的结果
        let nowTime = NSDate().timeIntervalSince1970
        if nowTime - missioncontrolLastDetectTime > 0.5 {
            ScrollCore.missioncontrolLastDetectTime = nowTime
            let windowInfoList = CGWindowListCopyWindowInfo(CGWindowListOption.optionOnScreenOnly, CGWindowID(0)) as [AnyObject]!
            for windowInfo in windowInfoList! {
                let windowName = windowInfo[kCGWindowName]!
                if windowName != nil && windowName as! String == "LPSpringboard" {
                    ScrollCore.launchpadActiveCache = true
                    return true
                }
            }
            ScrollCore.launchpadActiveCache = false
            return false
        } else {
            ScrollCore.missioncontrolLastDetectTime = nowTime
            return ScrollCore.launchpadActiveCache
        }
    }
    // 判断 MissionControl 是否激活
    static var missioncontrolActiveCache = false
    static var missioncontrolLastDetectTime = 0.0
    static func missioncontrolIsActive() -> Bool {
        // 如果距离上次检测时间大于500ms, 则重新检测一遍, 否则直接返回上次的结果
        let nowTime = NSDate().timeIntervalSince1970
        if nowTime - missioncontrolLastDetectTime > 0.5 {
            ScrollCore.missioncontrolLastDetectTime = nowTime
            let windowInfoList = CGWindowListCopyWindowInfo(CGWindowListOption.optionOnScreenOnly, CGWindowID(0)) as [AnyObject]!
            for windowInfo in windowInfoList! {
                let windowOwnerName = windowInfo[kCGWindowOwnerName]!
                if windowOwnerName != nil && windowOwnerName as! String == "Dock" {
                    if windowInfo[kCGWindowName]! == nil {
                        ScrollCore.missioncontrolActiveCache = true
                        return true
                    }
                }
            }
            ScrollCore.missioncontrolActiveCache = false
            return false
        } else {
            ScrollCore.missioncontrolLastDetectTime = nowTime
            return ScrollCore.missioncontrolActiveCache
        }
    }
    // 从 ScrollCore.ignoredApplications 中取回符合传入的 bundleId 的 IgnoredApplication 对象
    static func applicationInIgnoreListOf(bundleId: String?) -> IgnoredApplication? {
        if let id = bundleId {
            let appList = ScrollCore.ignoredApplications.filter {
                return $0.bundleId == id
            }
            return appList.count>0 ? appList[0] : nil
        }
        return nil
    }
    // 根据传入的 IgnoredApplication 对象判断是否需要禁止平滑滚动
    static func applicationNeedIgnoreSmooth(application: IgnoredApplication?) -> Bool {
        // 针对 Launchpad 和 MissionControl 特殊处理, 不论是否在列表内均禁用平滑
        if ScrollCore.launchpadIsActive() {
            return true
        }
        if ScrollCore.missioncontrolIsActive() {
            return true
        }
        // 一般 App
        if let app = application {
            return app.notSmooth
        }
        return false
    }
    // 根据 bundleId 判断程序是否在禁止平滑滚动列表内
    static func applicationInSmoothIgnoreList(bundleId: String?) -> Bool {
        // 针对 Launchpad 和 MissionControl 特殊处理, 不论是否在列表内均禁用平滑
        if ScrollCore.launchpadIsActive() {
            return true
        }
        if ScrollCore.missioncontrolIsActive() {
            return true
        }
        // 一般 App
        if let id = bundleId {
            return ScrollCore.ignoreList.smooth.contains(id)
        }
        return false
    }
    // 根据传入的 IgnoredApplication 对象判断是否需要禁止翻转滚动
    static func applicationNeedIgnoreReverse(application: IgnoredApplication?) -> Bool {
        // 针对 Launchpad 和 MissionControl 特殊处理
        if ScrollCore.ignoreList.reverse.contains("com.apple.launchpad.launcher") && ScrollCore.launchpadIsActive() {
            return true
        }
        if ScrollCore.ignoreList.reverse.contains("com.apple.exposelauncher") && ScrollCore.missioncontrolIsActive() {
            return true
        }
        // 一般 App
        if let app = application {
            return app.notReverse
        }
        return false
    }
    // 根据 bundleId 判断程序是否在禁止翻转滚动列表内
    static func applicationInReverseIgnoreList(bundleId: String?) -> Bool {
        // 针对 Launchpad 和 MissionControl 特殊处理
        if ScrollCore.ignoreList.reverse.contains("com.apple.launchpad.launcher") && ScrollCore.launchpadIsActive() {
            return true
        }
        if ScrollCore.ignoreList.reverse.contains("com.apple.exposelauncher") && ScrollCore.missioncontrolIsActive() {
            return true
        }
        // 一般 App
        if let id = bundleId {
            return ScrollCore.ignoreList.reverse.contains(id)
        }
        return false
    }
    // 是否启用平滑
    static func enableSmooth(ignoredApplicaton: IgnoredApplication?) -> Bool {
        let applicationInIgnoreList = ignoredApplicaton !== nil
        if ScrollCore.option.smooth {
            if ScrollCore.whiteListMode {
                if applicationInIgnoreList {
                    return !ScrollCore.applicationNeedIgnoreSmooth(application: ignoredApplicaton)
                } else {
                    return false
                }
            } else {
                return !ScrollCore.applicationNeedIgnoreSmooth(application: ignoredApplicaton)
            }
        } else {
            return false
        }
    }
    // 是否启用翻转
    static func enableReverse(ignoredApplicaton: IgnoredApplication?) -> Bool {
        let applicationInIgnoreList = ignoredApplicaton !== nil
        if ScrollCore.option.reverse {
            if ScrollCore.whiteListMode {
                if applicationInIgnoreList {
                    return !ScrollCore.applicationNeedIgnoreReverse(application: ignoredApplicaton)
                } else {
                    return false
                }
            } else {
                return !ScrollCore.applicationNeedIgnoreReverse(application: ignoredApplicaton)
            }
        } else {
            return false
        }
    }
    
    
    // 打印Log
    static func printLog(of event: CGEvent) {
        print(ScrollCore.getScrollLog(of: event))
    }
    // 获取滚动相关信息
    static func getScrollLog(of event: CGEvent) -> String {
        return (
            "Is using TouchPad: \(ScrollCore.isTouchPad(of: event))\n" +
            "Fix Y: \(event.getDoubleValueField(.scrollWheelEventDeltaAxis1))\n" +
            "Fix X: \(event.getDoubleValueField(.scrollWheelEventDeltaAxis2))\n" +
            "Pt Y: \(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))\n" +
            "Pt X: \(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))\n" +
            "Fix Pt Y: \(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))\n" +
            "Fix Pt X: \(event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2))\n"
        )
    }
    // 获取处理进程相关信息
    static func getScrollDetailLog(of event: CGEvent) -> String {
        return (
            "scrollWheelEventInstantMouser: \(event.getDoubleValueField(.scrollWheelEventInstantMouser))\n" +
            // 该字段影响采样精度, 设为1时为像素级别
            "scrollWheelEventIsContinuous: \(event.getDoubleValueField(.scrollWheelEventIsContinuous))\n" +
            // 加速度累计
            "scrollWheelEventScrollCount: \(event.getDoubleValueField(.scrollWheelEventScrollCount))\n" +
            // 该字段根据触控板响应阶段改变
            "scrollWheelEventMomentumPhase: \(event.getDoubleValueField(.scrollWheelEventMomentumPhase))\n" +
            // 该字段根据触控板响应阶段改变, 128:双指触碰未滑动,8:双指触碰未滑动拿开,2:双指滑动中/MM左侧滚轮滑动中,4:双指滑动完拿开,0:双指未在触控板上(是滑动事件缓动或滚轮)
            "scrollWheelEventScrollPhase: \(event.getDoubleValueField(.scrollWheelEventScrollPhase))\n"
        )
    }
    // 获取鼠标其他信息
    static func getOtherLog(of event: CGEvent) -> String {
        return (
            "mouseEventNumber: \(event.getDoubleValueField(.mouseEventNumber))\n" +
            "mouseEventClickState: \(event.getDoubleValueField(.mouseEventClickState))\n" +
            "mouseEventPressure: \(event.getDoubleValueField(.mouseEventPressure))\n" +
            "mouseEventButtonNumber: \(event.getDoubleValueField(.mouseEventButtonNumber))\n" +
            "mouseEventDeltaX: \(event.getDoubleValueField(.mouseEventDeltaX))\n" +
            "mouseEventDeltaY: \(event.getDoubleValueField(.mouseEventDeltaY))\n" +
            "mouseEventInstantMouser: \(event.getDoubleValueField(.mouseEventInstantMouser))\n" +
            "mouseEventSubtype: \(event.getDoubleValueField(.mouseEventSubtype))\n" +
            "mouseEventWindowUnderMousePointer: \(event.getDoubleValueField(.mouseEventWindowUnderMousePointer))\n" +
            "mouseEventWindowUnderMousePointerThatCanHandleThisEvent: \(event.getDoubleValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))\n"
        )
    }
    // 获取处理进程相关信息
    static func getProcessLog(of event: CGEvent) -> String {
        return (
            "eventTargetProcessSerialNumber: \(event.getDoubleValueField(.eventTargetProcessSerialNumber))\n" +
            "eventTargetUnixProcessID: \(event.getDoubleValueField(.eventTargetUnixProcessID))\n" +
            "eventSourceUnixProcessID: \(event.getDoubleValueField(.eventSourceUnixProcessID))\n" +
            "eventSourceUserData: \(event.getDoubleValueField(.eventSourceUserData))\n" +
            "eventSourceUserID: \(event.getDoubleValueField(.eventSourceUserID))\n" +
            "eventSourceGroupID: \(event.getDoubleValueField(.eventSourceGroupID))\n" +
            "eventSourceStateID: \(event.getDoubleValueField(.eventSourceStateID))\n"
        )
    }
    // 获取tablet(画板)相关信息
    static func getTabletLog(of event: CGEvent) -> String {
        return (
            "tabletEventPointX: \(event.getDoubleValueField(.tabletEventPointX))\n" +
            "tabletEventPointY: \(event.getDoubleValueField(.tabletEventPointY))\n" +
            "tabletEventPointZ: \(event.getDoubleValueField(.tabletEventPointZ))\n" +
            "tabletEventPointButtons: \(event.getDoubleValueField(.tabletEventPointButtons))\n" +
            "tabletEventPointPressure: \(event.getDoubleValueField(.tabletEventPointPressure))\n" +
            "tabletEventTiltX: \(event.getDoubleValueField(.tabletEventTiltX))\n" +
            "tabletEventTiltY: \(event.getDoubleValueField(.tabletEventTiltY))\n" +
            "tabletEventRotation: \(event.getDoubleValueField(.tabletEventRotation))\n" +
            "tabletEventTangentialPressure: \(event.getDoubleValueField(.tabletEventTangentialPressure))\n" +
            "tabletEventDeviceID: \(event.getDoubleValueField(.tabletEventDeviceID))\n" +
            "tabletEventVendor1: \(event.getDoubleValueField(.tabletEventVendor1))\n" +
            "tabletEventVendor2: \(event.getDoubleValueField(.tabletEventVendor2))\n" +
            "tabletEventVendor3: \(event.getDoubleValueField(.tabletEventVendor3))\n" +
            "tabletProximityEventVendorID: \(event.getDoubleValueField(.tabletProximityEventVendorID))\n" +
            "tabletProximityEventTabletID: \(event.getDoubleValueField(.tabletProximityEventTabletID))\n" +
            "tabletProximityEventPointerID: \(event.getDoubleValueField(.tabletProximityEventPointerID))\n" +
            "tabletProximityEventDeviceID: \(event.getDoubleValueField(.tabletProximityEventDeviceID))\n" +
            "tabletProximityEventSystemTabletID: \(event.getDoubleValueField(.tabletProximityEventSystemTabletID))\n" +
            "tabletProximityEventVendorPointerType: \(event.getDoubleValueField(.tabletProximityEventVendorPointerType))\n" +
            "tabletProximityEventVendorPointerSerialNumber: \(event.getDoubleValueField(.tabletProximityEventVendorPointerSerialNumber))\n" +
            "tabletProximityEventVendorUniqueID: \(event.getDoubleValueField(.tabletProximityEventVendorUniqueID))\n" +
            "tabletProximityEventCapabilityMask: \(event.getDoubleValueField(.tabletProximityEventCapabilityMask))\n" +
            "tabletProximityEventPointerType: \(event.getDoubleValueField(.tabletProximityEventPointerType))\n" +
            "tabletProximityEventEnterProximity: \(event.getDoubleValueField(.tabletProximityEventEnterProximity))\n"
        )
    }
}
