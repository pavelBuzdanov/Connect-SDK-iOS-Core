//
//  DevicePicker.m
//  Connect SDK
//
//  Created by Andrew Longstaff on 9/6/13.
//  Copyright (c) 2014 LG Electronics.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "DevicePicker.h"
#import "DiscoveryProvider.h"
#import "DiscoveryManager.h"

@implementation DevicePicker
{
    NSArray *_generatedDeviceList;
    NSArray *_actionSheetDeviceList;
    NSMutableDictionary *_devices;
    
    UINavigationController *_navigationController;
    UITableViewController *_tableViewController;
    
    UIActionSheet *_actionSheet;
    UIView *_actionSheetTargetView;
    
    UIPopoverController *_popover;
    NSDictionary *_popoverParams;

    dispatch_queue_t _sortQueue;

    BOOL _isExternalPlaybackActive;
    BOOL _showServiceLabel;
}

-(BOOL) isExternalPlaybackActive {
    return _isExternalPlaybackActive;
}

-(void) setIsExternalPlaybackActive:(BOOL) isExternalPlaybackActive {
    _isExternalPlaybackActive = isExternalPlaybackActive;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (_tableViewController)
            [_tableViewController.tableView reloadData];
    });
}

- (instancetype) init
{
    self = [super init];

    if (self)
    {
        _sortQueue = dispatch_queue_create("Connect SDK Device Picker Sort", DISPATCH_QUEUE_SERIAL);
        _devices = [[NSMutableDictionary alloc] init];

        self.shouldAnimatePicker = YES;
        self.onlyDrmSupported = NO;
        self.isExternalPlaybackActive = NO;
    }

    return self;
}

- (void)setCurrentDevice:(ConnectableDevice *)currentDevice
{
    _currentDevice = currentDevice;

    [_tableViewController.tableView reloadData];
}

#pragma mark - Picker display methods

- (void) showPicker:(id)sender
{
    [self sortDevices];

    _showServiceLabel = [DiscoveryManager sharedManager].capabilityFilters.count == 0;

    NSString *pickerTitle = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Search_Title" value:@"Pick a device" table:@"ConnectSDK"];

    _tableViewController = [[UITableViewController alloc] initWithStyle:UITableViewStylePlain];
    _tableViewController.title = pickerTitle;
    _tableViewController.tableView.delegate = self;
    _tableViewController.tableView.dataSource = self;
    
    _navigationController = [[UINavigationController alloc] initWithRootViewController:_tableViewController];
    
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [indicator startAnimating];
    
    _tableViewController.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad)
        [self showPopover:sender];
    else
        [self showNavigation];
}

- (void) showPopover:(id)source
{
    _popover = [[UIPopoverController alloc] initWithContentViewController:_navigationController];
    _popover.delegate = self;
    
    if ([source isKindOfClass:[UIBarButtonItem class]])
    {
        [_popover presentPopoverFromBarButtonItem:source permittedArrowDirections:UIPopoverArrowDirectionAny animated:self.shouldAnimatePicker];
    } else if ([source isKindOfClass:[UIView class]])
    {
        UIView *sourceView = (UIView *)source;
        CGRect sourceRect;
        UIView *targetView;
        UIPopoverArrowDirection permittedArrowDirections;
        
        if (sourceView.superview && ![sourceView.superview isKindOfClass:[UIWindow class]])
        {
            sourceRect = sourceView.frame;
            targetView = sourceView.superview;
            permittedArrowDirections = UIPopoverArrowDirectionAny;
        } else
        {
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRotation) name:UIDeviceOrientationDidChangeNotification object:nil];
            
            sourceRect = sourceView.frame;
            targetView = sourceView;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wint-conversion"
            permittedArrowDirections = NULL;
#pragma clang diagnostic pop
            
            _popoverParams = @{
                               @"sourceView" : sourceView,
                               @"targetView" : targetView
                               };
        }
        
        [_popover presentPopoverFromRect:sourceRect inView:targetView permittedArrowDirections:permittedArrowDirections animated:self.shouldAnimatePicker];
    } else
    {
        DLog(@"Sender should be a subclass of either UIBarButtonItem or UIView");
        
        [self cleanupViews];
    }
}

- (void) showActionSheet:(id)sender
{
    NSString *pickerTitle = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Search_Title" value:@"Pick a device" table:@"ConnectSDK"];
    NSString *pickerCancel = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Search_Cancel" value:@"Cancel" table:@"ConnectSDK"];
    
    _actionSheet = [[UIActionSheet alloc] initWithTitle:pickerTitle
                                               delegate:self
                                      cancelButtonTitle:nil
                                 destructiveButtonTitle:nil
                                      otherButtonTitles:nil];

    @synchronized (_generatedDeviceList)
    {
        _actionSheetDeviceList = [_generatedDeviceList copy];
    }

    [_actionSheet addButtonWithTitle: @"AirPlay"];
    [_actionSheetDeviceList enumerateObjectsUsingBlock:^(ConnectableDevice *device, NSUInteger idx, BOOL *stop)
    {
        [_actionSheet addButtonWithTitle: device.friendlyName];
    }];
    
    _actionSheet.cancelButtonIndex = [_actionSheet addButtonWithTitle:pickerCancel];
    
    if ([sender isKindOfClass:[UIBarButtonItem class]])
        [_actionSheet showFromBarButtonItem:sender animated:_shouldAnimatePicker];
    else if ([sender isKindOfClass:[UITabBar class]])
        [_actionSheet showFromTabBar:sender];
    else if ([sender isKindOfClass:[UIToolbar class]])
        [_actionSheet showFromToolbar:sender];
    else if ([sender isKindOfClass:[UIControl class]])
    {
        UIControl *senderView = (UIControl *)sender;
        [_actionSheet showFromRect:senderView.frame inView:senderView.superview animated:_shouldAnimatePicker];
    } else
    {
        [_actionSheet showInView:sender];
        
        _actionSheetTargetView = sender;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRotation) name:UIDeviceOrientationDidChangeNotification object:nil];
    }
}

-(UIViewController *)rootViewController {
    if (@available(iOS 13, *)) {
        NSArray *scenes = [[[UIApplication sharedApplication] connectedScenes] allObjects];
        for (UIWindowScene *scene in scenes) {
            NSArray *windows = [scene windows];
            for (UIWindow  *window in windows) {
                if (window.isKeyWindow) {
                    return window.rootViewController;
                }
            }
        }

        return nil;
    } else {
        return [UIApplication sharedApplication].keyWindow.rootViewController;
    }

}

- (UIViewController *)topViewController {
    UIViewController *topViewController = [self rootViewController];

    while (topViewController.presentedViewController) {
        topViewController = topViewController.presentedViewController;
    }
    return topViewController;
}

- (void) showNavigation
{
    NSString *pickerCancel = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Search_Cancel" value:@"Cancel" table:@"ConnectSDK"];

    _tableViewController.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:pickerCancel style:UIBarButtonItemStylePlain target:self action:@selector(dismissPicker:)];
    
    [[self topViewController] presentViewController:_navigationController animated:self.shouldAnimatePicker completion:nil];
}

- (void) dismissPicker:(id)sender
{
    [self dismissPicker:nil completion:nil];
}

- (void) dismissPicker:(id)sender completion: (void (^ __nullable)(void))completion
{
    if (_actionSheet)
    {
        [_actionSheet dismissWithClickedButtonIndex:_actionSheet.cancelButtonIndex animated:YES];
    } else
    {
        if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            [_popover dismissPopoverAnimated:_shouldAnimatePicker];
            completion();
        } else {
            [_navigationController dismissViewControllerAnimated:_shouldAnimatePicker  completion:completion];
        }
    }

    [self cleanupViews];

    if (self.delegate && [self.delegate respondsToSelector:@selector(devicePicker:didCancelWithError:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate devicePicker:self didCancelWithError:nil];
        });
    }
}

#pragma mark - Helper methods

- (void) cleanupViews
{
    if (_tableViewController)
    {
        _tableViewController.tableView.delegate = nil;
        _tableViewController.tableView.dataSource = nil;
    }
    
    if (_popover)
        _popover.delegate = nil;

    if (_actionSheet)
        _actionSheet.delegate = nil;

    _actionSheetTargetView = nil;
    _actionSheet = nil;
    _actionSheetDeviceList = nil;
    _navigationController = nil;
    _tableViewController = nil;
    _popoverParams = nil;
    _popover = nil;
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
}

- (void) sortDevices
{
    dispatch_async(_sortQueue, ^{
        NSArray *devices;

        @synchronized (_devices) { devices = [_devices allValues]; }

        @synchronized (_generatedDeviceList)
        {
                    NSArray <NSString *> *supportedSerivces;
            if (_onlyDrmSupported) {
                supportedSerivces = @[@"None"];
            } else {
                supportedSerivces = @[@"Chromecast", @"Chromecast, DIAL"];
            }
            NSPredicate *filter = [NSPredicate predicateWithFormat: @"connectedServiceNames IN %@", supportedSerivces];
            _generatedDeviceList = [[devices filteredArrayUsingPredicate: filter] sortedArrayUsingComparator:^NSComparisonResult(ConnectableDevice *device1, ConnectableDevice *device2) {
                NSString *device1Name = [[self nameForDevice:device1] lowercaseString];
                NSString *device2Name = [[self nameForDevice:device2] lowercaseString];

                return [device1Name compare:device2Name];
            }];
        }
    });
}

- (NSString *) nameForDevice:(ConnectableDevice *)device
{
    NSString *name;
    
    if (device.serviceDescription.friendlyName && device.serviceDescription.friendlyName.length > 0)
        name = device.serviceDescription.friendlyName;
    else if (device.serviceDescription.address && device.serviceDescription.address.length > 0)
        name = device.serviceDescription.address;
    else
        name = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_Unnamed_Device" value:@"Unnamed device" table:@"ConnectSDK"];
    
    return name;
}

- (void) handleRotation
{
    if (!self.shouldAutoRotate)
        return;
    
    if (_popover && _popoverParams)
    {
        UIView *sourceView = [_popoverParams objectForKey:@"sourceView"];
        UIView *targetView = [_popoverParams objectForKey:@"targetView"];
        
        if (!sourceView || !targetView)
            return;
        
        CGRect sourceRect = sourceView.bounds;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wint-conversion"
        UIPopoverArrowDirection permittedArrowDirections = NULL;
#pragma clang diagnostic pop
        
        [_popover presentPopoverFromRect:sourceRect inView:targetView permittedArrowDirections:permittedArrowDirections animated:self.shouldAnimatePicker];
    } else if (_actionSheet && _actionSheetTargetView)
    {
        [_actionSheet showInView:_actionSheetTargetView];
    }
}

#pragma mark UIActionSheet methods

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex
{
    if (buttonIndex == actionSheet.cancelButtonIndex)
        return;

    if (buttonIndex == 0) {
        if (self.delegate && [self.delegate respondsToSelector:@selector(devicePickerDidSelectAirPlay)])
        {
            dispatch_async(dispatch_get_main_queue(), ^
            {
                [self.delegate devicePickerDidSelectAirPlay];
            });
        }

        return;
    }

    ConnectableDevice *device = [_actionSheetDeviceList objectAtIndex:buttonIndex - 1];
    BOOL deviceExists = YES;

    @synchronized (_generatedDeviceList)
    {
        deviceExists = [_generatedDeviceList containsObject:device];
    }

    if (!deviceExists)
    {
        DLog(@"User selected a device that no longer exists");
        return;
    }

    if (self.delegate && [self.delegate respondsToSelector:@selector(devicePicker:didSelectDevice:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^
        {
            [self.delegate devicePicker:self didSelectDevice:device];
        });
    }
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex
{
    [self cleanupViews];
}

- (void)actionSheetCancel:(UIActionSheet *)actionSheet
{
    [self dismissPicker:nil completion:nil];
}

#pragma mark UITableViewDelegate methods

-(void) disconnectDevice: (ConnectableDevice *) device {
    if (_delegate && [_delegate respondsToSelector:@selector(devicePicker:userDisconnect:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_delegate devicePicker: self userDisconnect:device];
        });
    }

    [self.currentDevice disconnect];
    [self setCurrentDevice: nil];
}

-(void) showAlertForDisconnectDevice: (ConnectableDevice *) device {
    NSString *disconnectingAlertViewTitle = device.serviceDescription.friendlyName;
    NSString *disconnectingAlertViewMessage = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_DevicePicker_Disconnect_Description" value:@"Do you want to disconnect from the device?" table:@"ConnectSDK"];
    NSString *disconnectingAlertViewOk = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_DevicePicker_Disconnect_OK" value:@"YES" table:@"ConnectSDK"];
    NSString *disconnectingAlertViewCancel = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_DevicePicker_Disconnect_Cancel" value:@"NO" table:@"ConnectSDK"];

    UIAlertController *disconnectingAlertView = [UIAlertController alertControllerWithTitle:disconnectingAlertViewTitle message:disconnectingAlertViewMessage preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:disconnectingAlertViewCancel style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { }];

    UIAlertAction *okAction = [UIAlertAction actionWithTitle:disconnectingAlertViewOk style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self disconnectDevice: device];
    }];

    [disconnectingAlertView addAction:cancelAction];
    [disconnectingAlertView addAction:okAction];

    dispatch_on_main(^{
        [[self topViewController] presentViewController: disconnectingAlertView animated: YES completion: nil];
    });
}

-(void) showAlertForDisconnectAirplayDeviceWithTitle: (NSString *)disconnectingAlertViewTitle {
    NSString *disconnectingAlertViewMessage = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_DevicePicker_Disconnect_Description" value:@"Do you want to disconnect from the device?" table:@"ConnectSDK"];
    NSString *disconnectingAlertViewOk = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_DevicePicker_Disconnect_OK" value:@"YES" table:@"ConnectSDK"];
    NSString *disconnectingAlertViewCancel = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_DevicePicker_Disconnect_Cancel" value:@"NO" table:@"ConnectSDK"];

    UIAlertController *disconnectingAlertView = [UIAlertController alertControllerWithTitle:disconnectingAlertViewTitle message:disconnectingAlertViewMessage preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:disconnectingAlertViewCancel style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { }];

    UIAlertAction *okAction = [UIAlertAction actionWithTitle:disconnectingAlertViewOk style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (_delegate && [_delegate respondsToSelector:@selector(devicePickerDidSelectAirPlay)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_delegate devicePickerDidSelectAirPlay];
            });
        }
    }];

    [disconnectingAlertView addAction:cancelAction];
    [disconnectingAlertView addAction:okAction];

    dispatch_on_main(^{
        [[self topViewController] presentViewController: disconnectingAlertView animated: YES completion: nil];
    });
}

- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.row == 0) {
        if (self.currentDevice) {
            [self showAlertForDisconnectDevice: self.currentDevice];
        } else if (self.isExternalPlaybackActive) {
            [self showAlertForDisconnectAirplayDeviceWithTitle: @"AirPlay Device"];
        } else {
            [self dismissPicker:self  completion: ^{
                if (_delegate && [_delegate respondsToSelector:@selector(devicePickerDidSelectAirPlay)])
                {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [_delegate devicePickerDidSelectAirPlay];
                    });
                }
            }];
        }
        return;
    }

    if (self.isExternalPlaybackActive) {
        NSString *disconnectingAlertViewTitle = [[NSBundle mainBundle] localizedStringForKey:@"Connect_SDK_DevicePicker_Disconnect_Title" value:@"You are already connected to %@" table:@"ConnectSDK"];
        NSString *airplayDeviceTitle = @"AirPlay Device";
        [self showAlertForDisconnectAirplayDeviceWithTitle: [NSString stringWithFormat: disconnectingAlertViewTitle, airplayDeviceTitle]];
        return;
    }
    
    ConnectableDevice *device;

    @synchronized (_generatedDeviceList)
    {
        device = (ConnectableDevice *) [_generatedDeviceList objectAtIndex:indexPath.row - 1];
    }
    
    if (self.currentDevice)
    {
        if ([self.currentDevice.serviceDescription.address isEqualToString: device.serviceDescription.address]) {
            // вызвать диалог дисконнекта
            [self showAlertForDisconnectDevice: device];
            return;
        }
    }
    
    [self dismissPicker:self  completion: ^{
        if (_delegate && [_delegate respondsToSelector:@selector(devicePicker:didSelectDevice:)])
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_delegate devicePicker:self didSelectDevice:device];
            });
        }
    }];

}

#pragma mark UITableViewDataSource methods

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSInteger numberOfRows = 0;

    @synchronized (_generatedDeviceList)
    {
        if (_generatedDeviceList)
            numberOfRows = _generatedDeviceList.count + 1;
    }

    return numberOfRows;
}

static NSString *cellIdentifier = @"connectPickerCell";

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];

    if (cell == nil)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellIdentifier];


    if (indexPath.row == 0) {
        UIImage* image = [UIImage imageNamed: @"AirPlay"];
        cell.imageView.image = [image imageWithRenderingMode: UIImageRenderingModeAlwaysTemplate];
        [cell.imageView setTintColor: UIColor.labelColor];
        [cell.textLabel setText: @"AirPlay Devices"];
        [cell.detailTextLabel setText: @"AirPlay"];
        if (self.isExternalPlaybackActive) {
            [cell setAccessoryType:UITableViewCellAccessoryCheckmark];
        } else {
            [cell setAccessoryType:UITableViewCellAccessoryNone];
        }

        return cell;
    }


    ConnectableDevice *device;

    @synchronized (_generatedDeviceList)
    {
        if (_generatedDeviceList.count > 0 && (indexPath.row - 1) < _generatedDeviceList.count)
            device = (ConnectableDevice *) [_generatedDeviceList objectAtIndex: indexPath.row - 1];
    }

    if (!device)
        return cell;

    NSString *deviceName = [self nameForDevice:device];
    [cell.textLabel setText:deviceName];
    UIImage *image = [UIImage imageNamed: @"Chromecast"];
    cell.imageView.image = [image imageWithRenderingMode: UIImageRenderingModeAlwaysTemplate];
    [cell.imageView setTintColor: UIColor.labelColor];

    #ifdef DEBUG
        [cell.detailTextLabel setText:[device connectedServiceNames]];
    #endif

        if (_showServiceLabel)
            [cell.detailTextLabel setText:[device connectedServiceNames]];

        if (self.currentDevice)
        {
            if ([self.currentDevice.serviceDescription.address isEqualToString:device.serviceDescription.address])
                [cell setAccessoryType:UITableViewCellAccessoryCheckmark];
            else
                [cell setAccessoryType:UITableViewCellAccessoryNone];
        } else {
            [cell setAccessoryType:UITableViewCellAccessoryNone];
        }

    return cell;
}

#pragma mark - UIPopoverControllerDelegate methods

- (void)popoverControllerDidDismissPopover:(UIPopoverController *)popoverController
{
    if (self.delegate && [self.delegate respondsToSelector:@selector(devicePicker:didCancelWithError:)])
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate devicePicker:self didCancelWithError:nil];
        });
    }
    
    [self cleanupViews];
}

# pragma mark - DiscoveryManagerDelegate methods

- (void)discoveryManager:(DiscoveryManager *)manager didFindDevice:(ConnectableDevice *)device
{
    if (_devices)
    {
        @synchronized (_devices) { [_devices setObject:device forKey:device.address]; }

        [self sortDevices];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (_tableViewController)
                [_tableViewController.tableView reloadData];
        });
    }
}

- (void)discoveryManager:(DiscoveryManager *)manager didLoseDevice:(ConnectableDevice *)device
{
    if (_devices)
    {
        @synchronized (_devices) { [_devices removeObjectForKey:device.address]; }

        [self sortDevices];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (_tableViewController)
                [_tableViewController.tableView reloadData];
        });
    }
}

- (void)discoveryManager:(DiscoveryManager *)manager didUpdateDevice:(ConnectableDevice *)device
{
    if (_devices)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_tableViewController)
                [_tableViewController.tableView reloadData];
        });
    }
}

@end
