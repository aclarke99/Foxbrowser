//
//  SGPageViewController.h
//  SGPageController
//
//  Created by Simon Grätzer on 13.12.12.
//
//
//  Copyright (c) 2012 Simon Grätzer
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "SGBrowserViewController.h"

@class SGPageToolbar;

@interface SGPageViewController : SGBrowserViewController <UIScrollViewDelegate, UIGestureRecognizerDelegate>
@property (weak, readonly, nonatomic) SGPageToolbar *toolbar;
@property (weak, readonly, nonatomic) UIScrollView *scrollView;
@property (weak, readonly, nonatomic) UIPageControl *pageControl;
@property (weak, readonly, nonatomic) UIButton *closeButton;
@property (weak, readonly, nonatomic) UIButton *addTabButton;
@property (weak, readonly, nonatomic) UIButton *menuButton;
@property (weak, readonly, nonatomic) UIButton *tabsButton;
@property (weak, readonly, nonatomic) UILabel *titleLabel;
@property (assign, nonatomic) BOOL exposeMode;

- (void)setExposeMode:(BOOL)exposeMode animated:(BOOL)animated;
@end
