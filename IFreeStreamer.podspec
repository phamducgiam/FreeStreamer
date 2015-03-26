Pod::Spec.new do |s|
	s.name                  = 'IFreeStreamer'
	s.version               = '1.0.0'
	s.license               = 'BSD'
	s.summary               = 'A low-memory footprint streaming audio client for iOS and OS X. Fork from https://github.com/muhku/FreeStreamer with improvements.'
	s.homepage              = 'http://phamducgiam.com'
	s.author                = { 'Matias Muhonen' => 'mmu@iki.fi', 'Pham Duc Giam' => 'phamducgiam@gmail.com' }
	s.source                = { :git => https://github.com/phamducgiam/FreeStreamer', :tag => s.version.to_s }
	s.ios.deployment_target = '6.0'
	s.osx.deployment_target = '10.7'
	s.source_files          = 'Common/*.{h,m,mm}', 'astreamer/*.{h,cpp}'
	s.ios.frameworks        = 'CFNetwork', 'AudioToolbox', 'AVFoundation', 'MediaPlayer'
	s.osx.frameworks        = 'CFNetwork', 'AudioToolbox', 'AVFoundation'
	s.libraries	        	= 'xml2', 'stdc++'
	s.xcconfig              = { 'HEADER_SEARCH_PATHS' => '$(SDKROOT)/usr/include/libxml2' }
	s.requires_arc          = true
    s.dependency 'Reachability', '~> 3.0'
end
