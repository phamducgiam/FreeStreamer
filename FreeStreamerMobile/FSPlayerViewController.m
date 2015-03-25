/*
 * This file is part of the FreeStreamer project,
 * (C)Copyright 2011-2015 Matias Muhonen <mmu@iki.fi>
 * See the file ''LICENSE'' for using the code.
 *
 * https://github.com/muhku/FreeStreamer
 */

#import "FSPlayerViewController.h"

#import <MediaPlayer/MediaPlayer.h>

#import "FSAudioStream.h"
#import "FSAudioController.h"
#import "FSPlaylistItem.h"
#import "FSFrequencyDomainAnalyzer.h"
#import "FSFrequencyPlotView.h"
#import "AJNotificationView.h"

/*
 * To pause after seeking, uncomment the following line:
 */
//#define PAUSE_AFTER_SEEKING 1

@interface FSPlayerViewController ()

- (void)clearStatus;
- (void)showStatus:(NSString *)status;
- (void)showErrorStatus:(NSString *)status;
- (void)updatePlaybackProgress;
- (void)rampVolume;
- (void)seekToNewTime;
- (void)determineStationNameWithMetaData:(NSDictionary *)metaData;
- (void)doSeeking;
- (void)finalizeSeeking;

@end

@implementation FSPlayerViewController

/*
 * =======================================
 * View control
 * =======================================
 */

- (void)didReceiveMemoryWarning
{
    // Releases the view if it doesn't have a superview.
    [super didReceiveMemoryWarning];
    
    // Release any cached data, images, etc that aren't in use.
}

#pragma mark - View lifecycle

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
#if (__IPHONE_OS_VERSION_MIN_REQUIRED >= 70000)
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleLightContent
                                                animated:NO];
#else
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque
                                                animated:NO];
#endif
    
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBarHidden = NO;
    
    self.nextButton.hidden = YES;
    self.previousButton.hidden = YES;
    
    _stationURL = nil;
    self.navigationItem.rightBarButtonItem = nil;
    
    self.view.backgroundColor = [UIColor clearColor];
    
    self.bufferingIndicator.hidden = YES;
    self.prebufferStatus.hidden = YES;
    
    [self.audioController setVolume:_outputVolume];
    self.volumeSlider.value = _outputVolume;
    
    _maxPrebufferedByteCount = (float)self.audioController.stream.configuration.maxPrebufferedByteCount;
    
    self.audioController.stream.onStateChange = ^(FSAudioStreamState state) {
        switch (state) {
            case kFsAudioStreamRetrievingURL:
                [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
                
                [self showStatus:@"Retrieving URL..."];
                
                self.statusLabel.text = @"";
                
                self.progressSlider.enabled = NO;
                self.playButton.hidden = YES;
                self.pauseButton.hidden = NO;
                _paused = NO;
                break;
                
            case kFsAudioStreamStopped:
                [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                
                self.statusLabel.text = @"";
                
                self.progressSlider.enabled = NO;
                self.playButton.hidden = NO;
                self.pauseButton.hidden = YES;
                _paused = NO;
                break;
                
            case kFsAudioStreamBuffering:
                [self showStatus:@"Buffering..."];
                
                [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
                self.progressSlider.enabled = NO;
                self.playButton.hidden = YES;
                self.pauseButton.hidden = NO;
                _paused = NO;
                break;
                
            case kFsAudioStreamSeeking:
                [self showStatus:@"Seeking..."];
                
                [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
                self.progressSlider.enabled = NO;
                self.playButton.hidden = YES;
                self.pauseButton.hidden = NO;
                _paused = NO;
                break;
                
            case kFsAudioStreamPlaying:
                [self determineStationNameWithMetaData:nil];
                
                [self clearStatus];
                
                [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                
                self.progressSlider.enabled = YES;
                
                if (!_progressUpdateTimer) {
                    _progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                                            target:self
                                                                          selector:@selector(updatePlaybackProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
                }
                
                if (_volumeBeforeRamping > 0) {
                    // If we have volume before ramping set, it means we were seeked
                    
#if PAUSE_AFTER_SEEKING
                    [self pause:self];
                    self.audioController.volume = _volumeBeforeRamping;
                    _volumeBeforeRamping = 0;
                    
                    break;
#else
                    _rampStep = 1;
                    _rampStepCount = 5; // 50ms and 5 steps = 250ms ramp
                    _rampUp = true;
                    _postRampAction = @selector(finalizeSeeking);
                    
                    _volumeRampTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 // 50ms
                                                                        target:self
                                                                      selector:@selector(rampVolume)
                                                                      userInfo:nil
                                                                       repeats:YES];
#endif
                }
                [self toggleNextPreviousButtons];
                self.playButton.hidden = YES;
                self.pauseButton.hidden = NO;
                _paused = NO;
                
                break;
                
            case kFsAudioStreamFailed:
                [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
                self.progressSlider.enabled = NO;
                self.playButton.hidden = NO;
                self.pauseButton.hidden = YES;
                _paused = NO;
                break;
            case kFsAudioStreamPlaybackCompleted:
                [self toggleNextPreviousButtons];
                break;

            default:
                break;
        }
    };
    
    self.audioController.stream.onFailure = ^(FSAudioStreamError error, NSString *errorDescription) {
        NSString *errorCategory;
        
        switch (error) {
            case kFsAudioStreamErrorOpen:
                errorCategory = @"Cannot open the audio stream: ";
                break;
            case kFsAudioStreamErrorStreamParse:
                errorCategory = @"Cannot read the audio stream: ";
                break;
            case kFsAudioStreamErrorNetwork:
                errorCategory = @"Network failed: cannot play the audio stream: ";
                break;
            case kFsAudioStreamErrorUnsupportedFormat:
                errorCategory = @"Unsupported format: ";
                break;
            case kFsAudioStreamErrorStreamBouncing:
                errorCategory = @"Network failed: cannot get enough data to play: ";
                break;
            default:
                errorCategory = @"Unknown error occurred: ";
                break;
        }
        
        NSString *formattedError = [NSString stringWithFormat:@"%@ %@", errorCategory, errorDescription];
        
        [self showErrorStatus:formattedError];
    };
    
    self.audioController.stream.onMetaDataAvailable = ^(NSDictionary *metaData) {
        NSMutableString *streamInfo = [[NSMutableString alloc] init];
        
        [self determineStationNameWithMetaData:metaData];
        
        NSMutableDictionary *songInfo = [[NSMutableDictionary alloc] init];
        
        if (metaData[@"MPMediaItemPropertyTitle"]) {
            songInfo[MPMediaItemPropertyTitle] = metaData[@"MPMediaItemPropertyTitle"];
        } else if (metaData[@"StreamTitle"]) {
            songInfo[MPMediaItemPropertyTitle] = metaData[@"StreamTitle"];
        }
        
        if (metaData[@"MPMediaItemPropertyArtist"]) {
            songInfo[MPMediaItemPropertyArtist] = metaData[@"MPMediaItemPropertyArtist"];
        }
        
        [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:songInfo];
        
        if (metaData[@"MPMediaItemPropertyArtist"] &&
            metaData[@"MPMediaItemPropertyTitle"]) {
            [streamInfo appendString:metaData[@"MPMediaItemPropertyArtist"]];
            [streamInfo appendString:@" - "];
            [streamInfo appendString:metaData[@"MPMediaItemPropertyTitle"]];
        } else if (metaData[@"StreamTitle"]) {
            [streamInfo appendString:metaData[@"StreamTitle"]];
        }
        
        if (metaData[@"StreamUrl"] && [metaData[@"StreamUrl"] length] > 0) {
            _stationURL = [NSURL URLWithString:metaData[@"StreamUrl"]];
            
            self.navigationItem.rightBarButtonItem = _infoButton;
        }
        
        [_statusLabel setHidden:NO];
        self.statusLabel.text = streamInfo;
    };
    
    self.audioController.stream.onRecordTrackAvailable = ^(NSString *recordDirectory, NSString *recordFile, NSDictionary *metadata, BOOL finish) {
        
    };
    
    self.audioController.stream.onRecordError = ^(NSError *error) {
        NSLog(@"error = %@", error.localizedDescription);
    };
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    if (_shouldStartPlaying) {
        _shouldStartPlaying = NO;
        
        if ([self.audioController.url isEqual:_lastPlaybackURL]) {
            // The same file was playing from a position, resume
            [self.audioController.stream playFromOffset:_lastSeekByteOffset];
        } else {
            [self.audioController play];
        }
    }
    
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    
    [self becomeFirstResponder];
    
    _progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                            target:self
                                                          selector:@selector(updatePlaybackProgress)
                                                          userInfo:nil
                                                           repeats:YES];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackgroundNotification:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForegroundNotification:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    // Hide the buttons as we display them based on the playback status (callback)
    self.playButton.hidden = YES;
    self.pauseButton.hidden = YES;
    
    _infoButton = self.navigationItem.rightBarButtonItem;
    
    _outputVolume = 0.5;
}

- (void)viewDidUnload
{
    [super viewDidUnload];
    // Release any retained subviews of the main view.
    // e.g. self.myOutlet = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
    return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (void)viewWillDisappear:(BOOL)animated
{
    [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    
    [self resignFirstResponder];
    
    if (!self.audioController.stream.continuous && self.audioController.isPlaying) {
        // If a file with a duration is playing, store its last known playback position
        // so that we can resume from the same position, if the same file
        // is played again
        
        _lastSeekByteOffset = self.audioController.stream.currentSeekByteOffset;
        _lastPlaybackURL = [self.audioController.url copy];
    } else {
        _lastPlaybackURL = nil;
    }
    
    [super viewWillDisappear:animated];
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    
    // Free the resources (audio queue, etc.)
    _audioController = nil;
    
    if (_analyzerEnabled) {
        [self toggleAnalyzer:self];
    }
    
    if (_progressUpdateTimer) {
        [_progressUpdateTimer invalidate], _progressUpdateTimer = nil;
    }
}

/*
 * =======================================
 * Observers
 * =======================================
 */

- (void)remoteControlReceivedWithEvent:(UIEvent *)receivedEvent
{
    if (receivedEvent.type == UIEventTypeRemoteControl) {
        switch (receivedEvent.subtype) {
            case UIEventSubtypeRemoteControlPause: /* FALLTHROUGH */
            case UIEventSubtypeRemoteControlPlay:  /* FALLTHROUGH */
            case UIEventSubtypeRemoteControlTogglePlayPause:
                if (_paused) {
                    [self play:self];
                } else {
                    [self pause:self];
                }
                break;
            default:
                break;
        }
    }
}

- (void)applicationDidEnterBackgroundNotification:(NSNotification *)notification
{
    _analyzer.enabled = NO;
}

- (void)applicationWillEnterForegroundNotification:(NSNotification *)notification
{
    _analyzer.enabled = _analyzerEnabled;
}

/*
 * =======================================
 * Stream control
 * =======================================
 */

- (IBAction)play:(id)sender
{
    if (_paused) {
        /*
         * If we are paused, call pause again to unpause so
         * that the stream playback will continue.
         */
        [self.audioController pause];
        _paused = NO;
    } else {
        /*
         * Not paused, just directly call play.
         */
        [self.audioController play];
    }
    
    self.playButton.hidden = YES;
    self.pauseButton.hidden = NO;
}

- (IBAction)pause:(id)sender
{
    [self.audioController pause];
    
    _paused = YES;
    
    self.playButton.hidden = NO;
    self.pauseButton.hidden = YES;
}

- (IBAction)seek:(id)sender
{
    _seekToPoint = self.progressSlider.value;
    
    [_progressUpdateTimer invalidate], _progressUpdateTimer = nil;
    
    [_playbackSeekTimer invalidate], _playbackSeekTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                                           target:self
                                                                                         selector:@selector(seekToNewTime)
                                                                                           userInfo:nil
                                                                                            repeats:NO];
}

- (IBAction)openStationUrl:(id)sender
{
    [self.audioController startRecording];
    //[[UIApplication sharedApplication] openURL:_stationURL];
}

- (IBAction)changeVolume:(id)sender
{
    self.audioController.volume = self.volumeSlider.value;
}

-(IBAction)playNext:(id)sender
{
    [self.audioController playNextItem];
}

-(IBAction)playPrevious:(id)sender
{
    [self.audioController playPreviousItem];
}

-(void)toggleNextPreviousButtons
{
    if([self.audioController hasNextItem] || [self.audioController hasPreviousItem])
    {
        self.nextButton.hidden = NO;
        self.previousButton.hidden = NO;
        self.nextButton.enabled = [self.audioController hasNextItem];
        self.previousButton.enabled = [self.audioController hasPreviousItem];
    }
    else
    {
        self.nextButton.hidden = YES;
        self.previousButton.hidden = YES;
    }
}

- (IBAction)toggleAnalyzer:(id)sender
{
    if ([self.audioController isRecording]) {
        [self.audioController stopRecording];
    }
    else {
        [self.audioController startRecording];
    }
    return;
    if (!_analyzerEnabled) {
        _analyzer = [[FSFrequencyDomainAnalyzer alloc] init];
        _analyzer.delegate = self.frequencyPlotView;
        _analyzer.enabled = YES;
        
        self.frequencyPlotView.hidden = NO;
        _audioController.stream.delegate = _analyzer;
    } else {
        _audioController.stream.delegate = nil;
        
        [self.frequencyPlotView reset];
        self.frequencyPlotView.hidden = YES;
        
        _analyzer.shouldExit = YES;
        _analyzer = nil;
    }
    
    _analyzerEnabled = (!_analyzerEnabled);
}

/*
 * =======================================
 * Properties
 * =======================================
 */

- (void)setSelectedPlaylistItem:(FSPlaylistItem *)selectedPlaylistItem
{
    _selectedPlaylistItem = selectedPlaylistItem;
    
    self.navigationItem.title = self.selectedPlaylistItem.title;
    
    self.audioController.url = self.selectedPlaylistItem.nsURL;
    //self.audioController.url = [NSURL URLWithString:@"http://stream-dc1.radioparadise.com/mp3-32"];
}

- (FSPlaylistItem *)selectedPlaylistItem
{
    return _selectedPlaylistItem;
}

- (FSAudioController *)audioController
{
    if (!_audioController) {
        _audioController = [[FSAudioController alloc] init];
    }
    return _audioController;
}

/*
 * =======================================
 * Private
 * =======================================
 */

- (void)clearStatus
{
    [AJNotificationView hideCurrentNotificationViewAndClearQueue];
}

- (void)showStatus:(NSString *)status
{
    [self clearStatus];
    
    [AJNotificationView showNoticeInView:[[[UIApplication sharedApplication] delegate] window]
                                    type:AJNotificationTypeDefault
                                   title:status
                         linedBackground:AJLinedBackgroundTypeAnimated
                               hideAfter:0];
}

- (void)showErrorStatus:(NSString *)status
{
    [self clearStatus];
    
    [AJNotificationView showNoticeInView:[[[UIApplication sharedApplication] delegate] window]
                                    type:AJNotificationTypeRed
                                   title:status
                               hideAfter:10];
}

- (void)updatePlaybackProgress
{
    if (self.audioController.stream.continuous) {
        self.progressSlider.enabled = NO;
        self.progressSlider.value = 0;
        self.currentPlaybackTime.text = @"";
    } else {
        self.progressSlider.enabled = YES;
        
        FSStreamPosition cur = self.audioController.stream.currentTimePlayed;
        FSStreamPosition end = self.audioController.stream.duration;
        
        self.progressSlider.value = cur.position;
        
        self.currentPlaybackTime.text = [NSString stringWithFormat:@"%i:%02i / %i:%02i",
                                         cur.minute, cur.second,
                                         end.minute, end.second];
    }
    
    self.bufferingIndicator.hidden = NO;
    self.prebufferStatus.hidden = YES;
    
    if (self.audioController.stream.contentLength > 0) {
        // A non-continuous stream, show the buffering progress within the whole file
        FSSeekByteOffset currentOffset = self.audioController.stream.currentSeekByteOffset;
        
        UInt64 totalBufferedData = currentOffset.start + self.audioController.stream.prebufferedByteCount;
        
        float bufferedDataFromTotal = (float)totalBufferedData / self.audioController.stream.contentLength;
        
        self.bufferingIndicator.progress = (float)currentOffset.start / self.audioController.stream.contentLength;
        
        // Use the status to show how much data we have in the buffers
        self.prebufferStatus.frame = CGRectMake(self.bufferingIndicator.frame.origin.x,
                                                self.bufferingIndicator.frame.origin.y,
                                                CGRectGetWidth(self.bufferingIndicator.frame) * bufferedDataFromTotal,
                                                5);
        self.prebufferStatus.hidden = NO;
    } else {
        // A continuous stream, use the buffering indicator to show progress
        // among the filled prebuffer
        self.bufferingIndicator.progress = (float)self.audioController.stream.prebufferedByteCount / _maxPrebufferedByteCount;
    }
}

- (void)rampVolume
{
    if (_rampStep > _rampStepCount) {
        [_volumeRampTimer invalidate], _volumeRampTimer = nil;
        
        if (_postRampAction) {
            [self performSelector:_postRampAction withObject:nil afterDelay:0];
        }
        
        return;
    }
    
    if (_rampUp) {
        self.audioController.volume = (_volumeBeforeRamping / _rampStepCount) * _rampStep;
    } else {
        self.audioController.volume = (_volumeBeforeRamping / _rampStepCount) * (_rampStepCount - _rampStep);
    }
    
    _rampStep++;
}

- (void)seekToNewTime
{
    self.progressSlider.enabled = NO;
    
    // Fade out the volume to avoid pops
    _volumeBeforeRamping = self.audioController.volume;
    
    if (_volumeBeforeRamping > 0) {
        _rampStep = 1;
        _rampStepCount = 5; // 50ms and 5 steps = 250ms ramp
        _rampUp = false;
        _postRampAction = @selector(doSeeking);
        
        _volumeRampTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 // 50ms
                                                            target:self
                                                          selector:@selector(rampVolume)
                                                          userInfo:nil
                                                           repeats:YES];
    } else {
        // Just directly seek, volume is already 0
        [self doSeeking];
    }
}

- (void)determineStationNameWithMetaData:(NSDictionary *)metaData
{
    if (metaData[@"IcecastStationName"] && [metaData[@"IcecastStationName"] length] > 0) {
        self.navigationController.navigationBar.topItem.title = metaData[@"IcecastStationName"];
    } else {
        FSPlaylistItem *playlistItem = self.audioController.currentPlaylistItem;
        NSString *title = playlistItem.title;
        
        if ([playlistItem.title length] > 0) {
            self.navigationController.navigationBar.topItem.title = title;
        } else {
            /* The last resort - use the URL as the title, if available */
            if (metaData[@"StreamUrl"] && [metaData[@"StreamUrl"] length] > 0) {
                self.navigationController.navigationBar.topItem.title = metaData[@"StreamUrl"];
            }
        }
    }
}

- (void)doSeeking
{
    FSStreamPosition pos = {0};
    pos.position = _seekToPoint;
    
    [self.audioController.stream seekToPosition:pos];
}

- (void)finalizeSeeking
{
    _volumeBeforeRamping = 0;
}

@end