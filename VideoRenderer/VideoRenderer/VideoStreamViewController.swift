//  Copyright © 2016 One by Aol : Publishers. All rights reserved.

import AVFoundation
import AVKit

class VideoStreamView: UIView {
    /// `AVPlayerLayer` class is returned as view backing layer.
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }
    
    fileprivate var playerLayer: AVPlayerLayer? {
        return layer as? AVPlayerLayer
    }
    
    fileprivate var player: AVPlayer? {
        get { return playerLayer?.player }
        set { playerLayer?.player = newValue }
    }
    
    deinit {
        player?.currentItem?.asset.cancelLoading()
    }
    
    private var naturalSize: CGSize? {
        guard
            let item = player?.currentItem,
            item.status == .readyToPlay,
            let track = item.asset.tracks(withMediaType: AVMediaTypeVideo).first else {
                return nil
        }
        
        return track.naturalSize
    }
    
    var resizeOptions = ResizeOptions(allowVerticalBars: true, allowHorizontalBars: true) {
        didSet {
            guard let size = naturalSize else { return }
            
            playerLayer?.videoGravity =
                resizeOptions.videoGravity(for: size, in: bounds.size)
        }
    }
    
    struct ResizeOptions {
        let allowVerticalBars: Bool
        let allowHorizontalBars: Bool
        
        func videoGravity(for videoSize: CGSize, in hostSize: CGSize) -> String {
            let videoAspectRatio = videoSize.width / videoSize.height
            let hostAspectRatio = hostSize.width / hostSize.height
            
            switch (allowVerticalBars, allowHorizontalBars) {
            case (false, false): return AVLayerVideoGravityResize
            case (true, true): return AVLayerVideoGravityResizeAspect
            case (true, false): return hostAspectRatio < videoAspectRatio
                ? AVLayerVideoGravityResize
                : AVLayerVideoGravityResizeAspect
            case (false, true): return hostAspectRatio > videoAspectRatio
                ? AVLayerVideoGravityResize
                : AVLayerVideoGravityResizeAspect
            }
        }
    }
}

extension Renderer.Descriptor {
    public static let flat = try! Renderer.Descriptor(
        id: "com.onemobilesdk.videorenderer.flat",
        version: "1.0"
    )
}


public final class VideoStreamViewController: UIViewController, RendererProtocol {
    public static let renderer = Renderer(
        descriptor: .flat,
        provider: { VideoStreamViewController() }
    )
    
    private var observer: SystemPlayerObserver?
    private var pictureInPictureObserver: PictureInPictureControllerObserver?
    
    private var timeObserver: Any?
    private var seekerController: SeekerController? = nil
    private var pictureInPictureController: AnyObject?
    
    override public func loadView() {
        view = VideoStreamView()
    }
    
    private var videoView: VideoStreamView? {
        return view as? VideoStreamView
    }
    
    private var player: AVPlayer? {
        get { return videoView?.player }
        set { videoView?.player = newValue }
    }
    
    public var dispatch: Renderer.Dispatch?
    
    public var props: Renderer.Props? {
        didSet {
            guard let props = props, view.window != nil else {
                if let timeObserver = timeObserver {
                    player?.removeTimeObserver(timeObserver)
                }
                
                player?.currentItem?.asset.cancelLoading()
                player?.replaceCurrentItem(with: nil)
                player = nil
                observer = nil
                pictureInPictureObserver = nil
                timeObserver = nil
                seekerController = nil
                
                return
            }
            
            #if os(iOS)
                if #available(iOS 9.0, *), isViewLoaded {
                    if pictureInPictureController == nil,
                        let layer = videoView?.playerLayer,
                        let pipController = AVPictureInPictureController(playerLayer: layer) {
                        pipController.delegate = self
                        pictureInPictureController = pipController
                    }
                }
                
            #endif
            
            let currentPlayer: AVPlayer
            
            if
                let player = player,
                let asset = player.currentItem?.asset as? AVURLAsset,
                props.content == asset.url {
                currentPlayer = player
            } else {
                if let timeObserver = timeObserver {
                    player?.removeTimeObserver(timeObserver)
                }
                timeObserver = nil
                
                currentPlayer = AVPlayer(url: props.content)
                
                observer = SystemPlayerObserver(player: currentPlayer) { [weak self] event in
                    switch event {
                    case .didChangeItemStatus(_, let new):
                        switch new {
                        case .failed:
                            let error: Error = {
                                guard let error = currentPlayer.currentItem?.error else {
                                    struct UnknownError: Error { let props: Renderer.Props }
                                    return UnknownError(props: props)
                                }
                                return error
                            }()
                            self?.dispatch?(.playbackFailed(error))
                        default: break
                        }
                    case .didChangeTimebaseRate(let new):
                        if new == 0 { self?.dispatch?(.playbackStopped) }
                        else { self?.dispatch?(.playbackStarted) }
                    case .didChangeItemDuration(_, let new):
                        guard let new = new else { return }
                        self?.dispatch?(.durationReceived(new))
                    case .didFinishPlayback:
                        self?.dispatch?(.playbackFinished)
                    case .didChangeLoadedTimeRanges(let new):
                        guard let end = new.last?.end else { return }
                        self?.dispatch?(.bufferedTimeUpdated(end))
                    case .didChangeAverageVideoBitrate(let new):
                        self?.dispatch?(.averageVideoBitrateUpdated(new))
                    default: break
                    }
                }
                
                player = currentPlayer
                seekerController = SeekerController(with: currentPlayer)
                
                if let pictureInPictureController = pictureInPictureController {
                    pictureInPictureObserver = PictureInPictureControllerObserver(
                        pictureInPictureController: pictureInPictureController,
                        emit: { [weak self] in
                            guard case .didChangedPossibility(let possible) = $0 else { return }
                            self?.dispatch?(.pictureInPictureIsPossible(possible))
                    })
                }
                
                if let item = player?.currentItem {
                    let key = "availableMediaCharacteristicsWithMediaSelectionOptions"
                    item.asset.loadValuesAsynchronously(forKeys: [key]) { [weak self] in
                        var error: NSError? = nil
                        let status = item.asset.statusOfValue(forKey: key, error: &error)
                        guard case .loaded = status else { return }
                        for characteristic in item.asset.availableMediaCharacteristicsWithMediaSelectionOptions {
                            guard let group = item.asset.mediaSelectionGroup(
                                forMediaCharacteristic: characteristic)
                                else { return }
                            let selectedOption = item.selectedMediaOption(in: group)
                            switch characteristic {
                            case AVMediaCharacteristicAudible:
                                self?.dispatch?(.audibleSelectionGroup(
                                    .init(
                                        selectedOption: selectedOption,
                                        group: group)))
                            case AVMediaCharacteristicLegible:
                                self?.dispatch?(.legibleSelectionGroup(
                                    .init(
                                        selectedOption: selectedOption,
                                        group: group)))
                            default: break
                            }
                        }
                    }
                }
            }
            
            guard currentPlayer.currentItem?.status == .readyToPlay else { return }
            
            //            videoView?.resizeOptions = VideoStreamView.ResizeOptions(
            //                allowVerticalBars: props.allowVerticalBars,
            //                allowHorizontalBars: props.allowHorizontalBars
            //            )
            
            seekerController?.process(to: props.newTime)
            
            if timeObserver == nil {
                timeObserver = currentPlayer.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
                    queue: nil,
                    using: { [weak self] time in
                        self?.dispatch?(.currentTimeUpdated(time))
                })
            }
            
            currentPlayer.volume = props.volume
            
            if currentPlayer.rate != props.rate {
                currentPlayer.rate = props.rate
            }
            
            #if os(iOS)
                if #available(iOS 9.0, *),
                    let pipController = pictureInPictureController as? AVPictureInPictureController {
                    
                    if props.pictureInPictureActive, !pipController.isPictureInPictureActive {
                        pipController.startPictureInPicture()
                    }
                    
                    if !props.pictureInPictureActive, pipController.isPictureInPictureActive {
                        pipController.stopPictureInPicture()
                    }
                }
            #endif
            
            func selectOption(for player: AVPlayer,
                              characteristic: String,
                              mediaSelection: Renderer.Props.MediaSelection) {
                guard let item = currentPlayer.currentItem else { return }
                guard let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) else { return }
                switch mediaSelection {
                case .on(let optionPropertyList):
                    let mediaOption = group.mediaSelectionOption(withPropertyList: optionPropertyList)
                    guard mediaOption != item.selectedMediaOption(in: group) else { return }
                    
                    item.select(mediaOption, in: group)
                case .off:
                    item.select(nil, in: group)
                case .disabled: break
                }
            }
            
            selectOption(for: currentPlayer,
                         characteristic: AVMediaCharacteristicAudible,
                         mediaSelection: props.audible)
            selectOption(for: currentPlayer,
                         characteristic: AVMediaCharacteristicLegible,
                         mediaSelection: props.legible)
        }
    }
}

#if os(iOS)
    @available(iOS 9.0, *)
    extension VideoStreamViewController: AVPictureInPictureControllerDelegate {
        public func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController) {
            dispatch?(.pictureInPictureStopped)
        }
    }
#endif
