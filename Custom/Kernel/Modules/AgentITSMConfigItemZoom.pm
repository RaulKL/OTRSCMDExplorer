# --
# Kernel/Modules/AgentITSMConfigItemZoom.pm - the OTRS ITSM config item zoom module
# Copyright (C) 2001-2013 OTRS AG, http://otrs.org/
# --
# $Id: AgentITSMConfigItemZoom.pm,v 1.15 2013/03/26 14:34:27 ub Exp $
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::Modules::AgentITSMConfigItemZoom;

use strict;
use warnings;

use Kernel::System::GeneralCatalog;
use Kernel::System::ITSMConfigItem;
use Kernel::System::LinkObject;

###### OTRSCMDBExplorer ######
use Kernel::System::CMDBExplorer;
use Kernel::System::Service;
use MIME::Base64;
###### OTRSCMDBExplorer ######

use vars qw($VERSION);
$VERSION = qw($Revision: 1.15 $) [1];

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {%Param};
    bless( $Self, $Type );

    # check needed objects
    for my $Object (qw(ParamObject DBObject LayoutObject LogObject ConfigObject)) {
        if ( !$Self->{$Object} ) {
            $Self->{LayoutObject}->FatalError( Message => "Got no $Object!" );
        }
    }
    $Self->{GeneralCatalogObject} = Kernel::System::GeneralCatalog->new(%Param);
    $Self->{ConfigItemObject}     = Kernel::System::ITSMConfigItem->new(%Param);
    $Self->{LinkObject}           = Kernel::System::LinkObject->new(%Param);

###### OTRSCMDBExplorer ######
    $Self->{ServiceObject} = Kernel::System::Service->new(%Param);
###### OTRSCMDBExplorer ######

    # get config of frontend module
    $Self->{Config} = $Self->{ConfigObject}->Get("ITSMConfigItem::Frontend::$Self->{Action}");

    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # get params
    my $ConfigItemID = $Self->{ParamObject}->GetParam( Param => 'ConfigItemID' ) || 0;
    my $VersionID    = $Self->{ParamObject}->GetParam( Param => 'VersionID' )    || 0;

    # check needed stuff
    if ( !$ConfigItemID ) {
        return $Self->{LayoutObject}->ErrorScreen(
            Message => "No ConfigItemID is given!",
            Comment => 'Please contact the admin.',
        );
    }

    # check for access rights
    my $HasAccess = $Self->{ConfigItemObject}->Permission(
        Scope  => 'Item',
        ItemID => $ConfigItemID,
        UserID => $Self->{UserID},
        Type   => $Self->{Config}->{Permission},
    );

    if ( !$HasAccess ) {

        # error page
        return $Self->{LayoutObject}->ErrorScreen(
            Message => 'Can\'t show item, no access rights for ConfigItem are given!',
            Comment => 'Please contact the admin.',
        );
    }

    # set show versions
    $Param{ShowVersions} = 0;
    if ( $Self->{ParamObject}->GetParam( Param => 'ShowVersions' ) ) {
        $Param{ShowVersions} = 1;
    }

    # get content
    my $ConfigItem = $Self->{ConfigItemObject}->ConfigItemGet(
        ConfigItemID => $ConfigItemID,
    );
    if ( !$ConfigItem->{ConfigItemID} ) {
        return $Self->{LayoutObject}->ErrorScreen(
            Message => "ConfigItemID $ConfigItemID not found in database!",
            Comment => 'Please contact the admin.',
        );
    }

    # get version list
    my $VersionList = $Self->{ConfigItemObject}->VersionZoomList(
        ConfigItemID => $ConfigItemID,
    );
    if ( !$VersionList->[0]->{VersionID} ) {
        return $Self->{LayoutObject}->ErrorScreen(
            Message => "No Version found for ConfigItemID $ConfigItemID!",
            Comment => 'Please contact the admin.',
        );
    }

    # set version id
    if ( !$VersionID ) {
        $VersionID = $VersionList->[-1]->{VersionID};
    }
    if ( $VersionID ne $VersionList->[-1]->{VersionID} ) {
        $Param{ShowVersions} = 1;
    }

    # set version id in param hash (only for menu module)
    if ($VersionID) {
        $Param{VersionID} = $VersionID;
    }

    # run config item menu modules
    if ( ref $Self->{ConfigObject}->Get('ITSMConfigItem::Frontend::MenuModule') eq 'HASH' ) {
        my %Menus   = %{ $Self->{ConfigObject}->Get('ITSMConfigItem::Frontend::MenuModule') };
        my $Counter = 0;
        for my $Menu ( sort keys %Menus ) {

            # load module
            if ( $Self->{MainObject}->Require( $Menus{$Menu}->{Module} ) ) {
                my $Object = $Menus{$Menu}->{Module}->new(
                    %{$Self},
                    ConfigItemID => $Self->{ConfigItemID},
                );

                # set classes
                if ( $Menus{$Menu}->{Target} ) {

                    if ( $Menus{$Menu}->{Target} eq 'PopUp' ) {
                        $Menus{$Menu}->{MenuClass} = 'AsPopup';
                    }
                    elsif ( $Menus{$Menu}->{Target} eq 'Back' ) {
                        $Menus{$Menu}->{MenuClass} = 'HistoryBack';
                    }

                }

                # run module
                $Counter = $Object->Run(
                    %Param,
                    ConfigItem => $ConfigItem,
                    Counter    => $Counter,
                    Config     => $Menus{$Menu},
                );
            }
            else {
                return $Self->{LayoutObject}->FatalError();
            }
        }
    }

    # build version tree
    $Self->{LayoutObject}->Block( Name => 'Tree' );
    my $Counter = 1;
    if ( !$Param{ShowVersions} && $VersionID eq $VersionList->[-1]->{VersionID} ) {
        $Counter     = @{$VersionList};
        $VersionList = [ $VersionList->[-1] ];
    }

    # get last version
    my $LastVersion = $VersionList->[-1];

    # set incident signal
    my %InciSignals = (
        operational => 'greenled',
        warning     => 'yellowled',
        incident    => 'redled',
    );

    # output version tree header
    if ( $Param{ShowVersions} ) {
        $Self->{LayoutObject}->Block(
            Name => 'Collapse',
            Data => {
                ConfigItemID => $ConfigItemID,
            },
        );
    }
    else {
        $Self->{LayoutObject}->Block(
            Name => 'Expand',
            Data => {
                ConfigItemID => $ConfigItemID,
            },
        );
    }

    # output version tree
    for my $VersionHash ( @{$VersionList} ) {

        my %UserInfo = $Self->{UserObject}->GetUserData(
            UserID => $VersionHash->{CreateBy},
            Cached => 1,
        );

        $Self->{LayoutObject}->Block(
            Name => 'TreeItem',
            Data => {
                %Param,
                %UserInfo,
                %{$ConfigItem},
                %{$VersionHash},
                Count      => $Counter,
                InciSignal => $InciSignals{ $VersionHash->{InciStateType} },
                Active     => $VersionHash->{VersionID} eq $VersionID ? 'Active' : '',
            },
        );

        $Counter++;
    }

    # output header
    my $Output = $Self->{LayoutObject}->Header( Value => $ConfigItem->{Number} );
    $Output .= $Self->{LayoutObject}->NavigationBar();

    # get version
    my $Version = $Self->{ConfigItemObject}->VersionGet(
        VersionID => $VersionID,
    );

    if (
        $Version
        && ref $Version eq 'HASH'
        && $Version->{XMLDefinition}
        && $Version->{XMLData}
        && ref $Version->{XMLDefinition} eq 'ARRAY'
        && ref $Version->{XMLData}       eq 'ARRAY'
        && $Version->{XMLData}->[1]
        && ref $Version->{XMLData}->[1] eq 'HASH'
        && $Version->{XMLData}->[1]->{Version}
        && ref $Version->{XMLData}->[1]->{Version} eq 'ARRAY'
        )
    {

        # transform ascii to html
        $Version->{Name} = $Self->{LayoutObject}->Ascii2Html(
            Text           => $Version->{Name},
            HTMLResultMode => 1,
            LinkFeature    => 1,
        );

        # output name
        $Self->{LayoutObject}->Block(
            Name => 'Data',
            Data => {
                Name        => 'Name',
                Description => 'The name of this config item',
                Value       => $Version->{Name},
                Identation  => 10,
            },
        );

        # output deployment state
        $Self->{LayoutObject}->Block(
            Name => 'Data',
            Data => {
                Name        => 'Deployment State',
                Description => 'The deployment state of this config item',
                Value       => $Self->{LayoutObject}->{LanguageObject}->Get(
                    $Version->{DeplState},
                ),
                Identation => 10,
            },
        );

        # output incident state
        $Self->{LayoutObject}->Block(
            Name => 'Data',
            Data => {
                Name        => 'Incident State',
                Description => 'The incident state of this config item',
                Value       => $Self->{LayoutObject}->{LanguageObject}->Get(
                    $Version->{InciState},
                ),
                Identation => 10,
            },
        );

        # start xml output
        $Self->_XMLOutput(
            XMLDefinition => $Version->{XMLDefinition},
            XMLData       => $Version->{XMLData}->[1]->{Version}->[1],
        );
    }

    # get create user data
    my %CreateUser = $Self->{UserObject}->GetUserData(
        UserID => $ConfigItem->{CreateBy},
        Cached => 1,
    );
    for my $Postfix (qw(UserLogin UserFirstname UserLastname)) {
        $ConfigItem->{ 'Create' . $Postfix } = $CreateUser{$Postfix};
    }

    # get change user data
    my %ChangeUser = $Self->{UserObject}->GetUserData(
        UserID => $ConfigItem->{ChangeBy},
        Cached => 1,
    );
    for my $Postfix (qw(UserLogin UserFirstname UserLastname)) {
        $ConfigItem->{ 'Change' . $Postfix } = $ChangeUser{$Postfix};
    }

    # output meta block
    $Self->{LayoutObject}->Block(
        Name => 'Meta',
        Data => {
            %{$LastVersion},
            %{$ConfigItem},
            CurInciSignal => $InciSignals{ $LastVersion->{CurInciStateType} },
        },
    );

    # get linked objects
    my $LinkListWithData = $Self->{LinkObject}->LinkListWithData(
        Object => 'ITSMConfigItem',
        Key    => $ConfigItemID,
        State  => 'Valid',
        UserID => $Self->{UserID},
    );

    # get link table view mode
    my $LinkTableViewMode = $Self->{ConfigObject}->Get('LinkObject::ViewMode');

    # create the link table
    my $LinkTableStrg = $Self->{LayoutObject}->LinkObjectTableCreate(
        LinkListWithData => $LinkListWithData,
        ViewMode         => $LinkTableViewMode,
    );

    # output the link table
    if ($LinkTableStrg) {
        $Self->{LayoutObject}->Block(
            Name => 'LinkTable' . $LinkTableViewMode,
            Data => {
                LinkTableStrg => $LinkTableStrg,
            },
        );
    }

###### OTRSCMDBExplorer ######
    my $Tracer = Kernel::System::CMDBExplorer->new(%{$Self}, Debug => 1);

    # Get graph parameters from URI
    my %TraceParams;
    my @RootCI = ( $ConfigItemID ); 
    $TraceParams{ConfigItemID} = \@RootCI; 
    my @DisplayedCIs;
    if ( $Self->{ParamObject}->GetParam( Param => 'DisplayedCIs' ) ) {
        @DisplayedCIs = split( ',' ,$Self->{ParamObject}->GetParam( Param => 'DisplayedCIs' ) );
    } else {
        @DisplayedCIs = @RootCI;
    }
    $TraceParams{DisplayedCIs} =  \@DisplayedCIs;
    $TraceParams{Layout} = $Self->{ParamObject}->GetParam( Param => 'Layout' ) || 'dot';
    $TraceParams{IA} = $Self->{ParamObject}->GetParam( Param => 'IA' ) || 0;

    # Display Impact analysis menu
    if ( $LastVersion->{CurInciStateType} ne 'operational' ) {
        if ( ! $TraceParams{IA} ) {
            $Self->{LayoutObject}->Block(
                 Name => 'GraphMenuItem',
                 Data => {
                     Link        => 'Action=AgentITSMConfigItemZoom;ConfigItemID=' . $ConfigItemID . ';Layout=' . $TraceParams{Layout} . ';IA=1',
                     MenuClass   => 'NoPopUp',
                     Name        => 'Impact',
                     Description => 'Show all impacted CIs',
                 },
            );
        } else {
            $Self->{LayoutObject}->Block(
                 Name => 'GraphMenuItem',
                 Data => {
                     Link        => 'Action=AgentITSMConfigItemZoom;ConfigItemID=' . $ConfigItemID . ';Layout=' . $TraceParams{Layout} . ';IA=0',
                     MenuClass   => 'NoPopUp',
                     Name        => 'Regular',
                     Description => 'Regular view',
                 },
            );
        } 
    }

    # Display graph layout selection field
    my $LayoutStrg = $Self->{LayoutObject}->BuildSelection(
         Name => 'Layout',
         Data => {
             dot   => 'dot',
             neato => 'neato',
             twopi => 'twopi',
             circo => 'circo',
             fdp   => 'fdp',
             sfdp  => 'sfdp',
         },
         SelectedValue => $TraceParams{Layout},
    );
    $Self->{LayoutObject}->Block(
         Name => 'GraphLayout',
         Data => {
             ConfigItemID => $ConfigItemID,
             DisplayedCIs => $Self->{ParamObject}->GetParam( Param => 'DisplayedCIs' ) || '',
             IA           => $TraceParams{IA},
             LayoutStrg   => $LayoutStrg,
         },
    );

    # Default trace constraints (Show all links and show only first-level children)
    my $LinkTypes = '';
    my $MaxTraceDepth = 1;
    my $CompactTrace = 1;

    # Does the agent requested Impact analysis?
    if ( $TraceParams{IA} == 1 ) {
        $LinkTypes = 'DependsOn';
        $MaxTraceDepth = 0;
        $CompactTrace = 0;
    }

    # Set Trace constraints (Still don't know the purpose of CompactTrace)
    $Tracer->SetConstraints( 
        CompactTrace => $CompactTrace,
        MaxTraceDepth => $MaxTraceDepth,
        LinkTypes => $LinkTypes,
    );

    # Create the graph
    my $Content = $Tracer->Trace( %TraceParams );

    # Add graph to output
    my $Base64EncodedPNG = encode_base64( $Content->{png} );
    $Self->{LayoutObject}->Block(
         Name => 'LinkGraph',
         Data => {
             Content => $Base64EncodedPNG,
             Map     => $Content->{map},
         },
    );
###### OTRSCMDBExplorer ######

    my @Attachments = $Self->{ConfigItemObject}->ConfigItemAttachmentList(
        ConfigItemID => $ConfigItemID,
    );

    if (@Attachments) {

        # get the metadata of the 1st attachment
        my $FirstAttachment = $Self->{ConfigItemObject}->ConfigItemAttachmentGet(
            ConfigItemID => $ConfigItemID,
            Filename     => $Attachments[0],
        );

        $Self->{LayoutObject}->Block(
            Name => 'Attachments',
            Data => {
                ConfigItemID => $ConfigItemID,
                Filename     => $FirstAttachment->{Filename},
                Filesize     => $FirstAttachment->{Filesize},
            },
        );

        # the 1st attachment was directly rendered into the 1st row's right cell, all further
        # attachments are rendered into a separate row
        ATTACHMENT:
        for my $Attachment (@Attachments) {

            # skip the 1st attachment
            next ATTACHMENT if $Attachment eq $Attachments[0];

            # get the metadata of the current attachment
            my $AttachmentData = $Self->{ConfigItemObject}->ConfigItemAttachmentGet(
                ConfigItemID => $ConfigItemID,
                Filename     => $Attachment,
            );

            $Self->{LayoutObject}->Block(
                Name => 'AttachmentRow',
                Data => {
                    ConfigItemID => $ConfigItemID,
                    Filename     => $AttachmentData->{Filename},
                    Filesize     => $AttachmentData->{Filesize},
                },
            );
        }
    }

    # handle DownloadAttachment
    if ( $Self->{Subaction} eq 'DownloadAttachment' ) {

        # get data for attachment
        my $Filename = $Self->{ParamObject}->GetParam( Param => 'Filename' );
        my $AttachmentData = $Self->{ConfigItemObject}->ConfigItemAttachmentGet(
            ConfigItemID => $ConfigItemID,
            Filename     => $Filename,
        );

        # return error if file does not exist
        if ( !$AttachmentData ) {
            $Self->{LogObject}->Log(
                Message  => "No such attachment ($Filename)!",
                Priority => 'error',
            );
            return $Self->{LayoutObject}->ErrorScreen();
        }

        return $Self->{LayoutObject}->Attachment(
            %{$AttachmentData},
            Type => 'attachment',
        );
    }

    # store last screen
    $Self->{SessionObject}->UpdateSessionID(
        SessionID => $Self->{SessionID},
        Key       => 'LastScreenView',
        Value     => $Self->{RequestedURL},
    );

    # start template output
    $Output .= $Self->{LayoutObject}->Output(
        TemplateFile => 'AgentITSMConfigItemZoom',
        Data         => {
            %{$LastVersion},
            %{$ConfigItem},
            CurInciSignal => $InciSignals{ $LastVersion->{CurInciStateType} },
        },
    );

    # add footer
    $Output .= $Self->{LayoutObject}->Footer();

    return $Output;
}

sub _XMLOutput {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    return if !$Param{XMLData};
    return if !$Param{XMLDefinition};
    return if ref $Param{XMLData} ne 'HASH';
    return if ref $Param{XMLDefinition} ne 'ARRAY';

    $Param{Level} ||= 0;

    ITEM:
    for my $Item ( @{ $Param{XMLDefinition} } ) {
        COUNTER:
        for my $Counter ( 1 .. $Item->{CountMax} ) {

            # stop loop, if no content was given
            last COUNTER if !defined $Param{XMLData}->{ $Item->{Key} }->[$Counter]->{Content};

            # lookup value
            my $Value = $Self->{ConfigItemObject}->XMLValueLookup(
                Item  => $Item,
                Value => $Param{XMLData}->{ $Item->{Key} }->[$Counter]->{Content},
            );

            # create output string
            $Value = $Self->{LayoutObject}->ITSMConfigItemOutputStringCreate(
                Value => $Value,
                Item  => $Item,
            );

            # calculate indentation for left-padding css based on 15px per level and 10px as default
            my $Indentation = 10;

            if ( $Param{Level} ) {
                $Indentation += 15 * $Param{Level};
            }

            # output data block
            $Self->{LayoutObject}->Block(
                Name => 'Data',
                Data => {
                    Name        => $Item->{Name},
                    Description => $Item->{Description} || $Item->{Name},
                    Value       => $Value,
                    Indentation => $Indentation,
                },
            );

            # start recursion, if "Sub" was found
            if ( $Item->{Sub} ) {
                $Self->_XMLOutput(
                    XMLDefinition => $Item->{Sub},
                    XMLData       => $Param{XMLData}->{ $Item->{Key} }->[$Counter],
                    Level         => $Param{Level} + 1,
                );
            }
        }
    }

    return 1;
}

1;
