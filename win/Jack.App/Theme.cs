// The look, matched to the Mac card (Sources/WordConvertCard.swift, ratified mock
// https://claude.ai/artifact/2wXnJg4C8GjD4U5wEp9Mvy): light panel, radius 16, 22 px inset from
// the screen corner, teal #0E6E6E accent, 34 px glyph with a teal gradient and a white stroke.
// Styles are XAML parsed at start-up (no compile-time XAML), so a typo shows up as a start-up
// failure in the CI smoke test, never silently.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Shapes;
using WpfPath = System.Windows.Shapes.Path;

namespace Jack.App;

internal static class Theme
{
    public static readonly Color TealC = Color.FromRgb(0x0E, 0x6E, 0x6E);
    public static readonly Brush Teal = Frozen(new SolidColorBrush(TealC));
    public static readonly Brush Ink = Frozen(new SolidColorBrush(Color.FromRgb(0x1D, 0x1D, 0x1F)));
    public static readonly Brush Secondary = Frozen(new SolidColorBrush(Color.FromRgb(0x6E, 0x6E, 0x73)));
    public static readonly Brush Heading = Frozen(new SolidColorBrush(Color.FromRgb(0x5B, 0x5F, 0x67)));
    public static readonly Brush Orange = Frozen(new SolidColorBrush(Color.FromRgb(0xB4, 0x5A, 0x09)));
    public static readonly Brush Highlight = Frozen(new SolidColorBrush(Color.FromRgb(0xFD, 0xE6, 0x8A)));
    public static readonly Brush Panel = Frozen(new SolidColorBrush(Color.FromRgb(0xFB, 0xFB, 0xFD)));
    public static readonly Brush Hairline = Frozen(new SolidColorBrush(Color.FromArgb(0x26, 0, 0, 0)));
    public static readonly Brush Grey = Frozen(new SolidColorBrush(Color.FromRgb(0x8E, 0x8E, 0x93)));
    public static readonly FontFamily Font = new("Segoe UI Variable Text, Segoe UI");

    static Brush Frozen(Brush b) { b.Freeze(); return b; }

    const string Xaml = """
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Style x:Key="Btn" TargetType="Button">
    <Setter Property="FontSize" Value="13"/>
    <Setter Property="Padding" Value="14,6"/>
    <Setter Property="Margin" Value="8,0,0,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Foreground" Value="#1D1D1F"/>
    <Setter Property="Background" Value="#FFFFFF"/>
    <Setter Property="BorderBrush" Value="#C9CBD1"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="1" CornerRadius="7" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.88"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.72"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="b" Property="BorderBrush" Value="#0A2540"/>
              <Setter TargetName="b" Property="BorderThickness" Value="2"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="#0E6E6E"/>
    <Setter Property="BorderBrush" Value="#0E6E6E"/>
    <Setter Property="Foreground" Value="#FFFFFF"/>
  </Style>
  <Style x:Key="Link" TargetType="Button">
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="FontWeight" Value="Medium"/>
    <Setter Property="Foreground" Value="#0E6E6E"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="Transparent" BorderBrush="Transparent" BorderThickness="0,0,0,1" Padding="1,0">
            <ContentPresenter VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#0E6E6E"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#0A2540"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Close" TargetType="Button">
    <Setter Property="Width" Value="22"/>
    <Setter Property="Height" Value="22"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="Transparent" CornerRadius="11" BorderThickness="1" BorderBrush="Transparent">
            <Path Data="M7,7 L15,15 M15,7 L7,15" Stroke="#6E6E73" StrokeThickness="1.6" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#14000000"/></Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#0A2540"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Zone" TargetType="Button">
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Grid>
            <Rectangle x:Name="r" RadiusX="11" RadiusY="11" Stroke="#BF0E8577" StrokeThickness="2" StrokeDashArray="3 2.5" Fill="Transparent"/>
            <ContentPresenter/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="r" Property="StrokeDashArray" Value="{x:Null}"/>
              <Setter TargetName="r" Property="Fill" Value="#1A0E8577"/>
            </Trigger>
            <Trigger Property="Tag" Value="hot">
              <Setter TargetName="r" Property="StrokeDashArray" Value="{x:Null}"/>
              <Setter TargetName="r" Property="Fill" Value="#1A0E8577"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="r" Property="Stroke" Value="#0A2540"/>
              <Setter TargetName="r" Property="StrokeDashArray" Value="{x:Null}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter TargetName="r" Property="Stroke" Value="#C9CBD1"/>
              <Setter Property="Cursor" Value="Arrow"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Bar" TargetType="ProgressBar">
    <Setter Property="Height" Value="4"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ProgressBar">
          <Grid ClipToBounds="True">
            <Border x:Name="PART_Track" Background="#E3E6EA" CornerRadius="2"/>
            <Border x:Name="PART_Indicator" Background="#0E6E6E" CornerRadius="2" HorizontalAlignment="Left"/>
            <Border x:Name="Glide" Background="#0E6E6E" CornerRadius="2" Width="70" HorizontalAlignment="Left" Visibility="Collapsed">
              <Border.RenderTransform><TranslateTransform X="-70"/></Border.RenderTransform>
            </Border>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsIndeterminate" Value="True">
              <Setter TargetName="PART_Indicator" Property="Visibility" Value="Collapsed"/>
              <Setter TargetName="Glide" Property="Visibility" Value="Visible"/>
              <Trigger.EnterActions>
                <BeginStoryboard>
                  <Storyboard RepeatBehavior="Forever">
                    <DoubleAnimation Storyboard.TargetName="Glide"
                                     Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                     From="-70" To="380" Duration="0:0:1.4"/>
                  </Storyboard>
                </BeginStoryboard>
              </Trigger.EnterActions>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
""";

    static ResourceDictionary? styles;
    public static ResourceDictionary Styles => styles ??= (ResourceDictionary)XamlReader.Parse(Xaml);
    public static Style Style(string key) => (Style)Styles[key];

    // MARK: - Text

    public static TextBlock Text(string s, double size, Brush? color = null, FontWeight? weight = null, bool wrap = true)
        => new()
        {
            Text = s, FontSize = size, Foreground = color ?? Ink, FontWeight = weight ?? FontWeights.Normal,
            FontFamily = Font, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        };

    public static Button Button(string label, string style, Action click, string? automationName = null)
    {
        var b = new Button { Content = label, Style = Style(style), FontFamily = Font };
        System.Windows.Automation.AutomationProperties.SetName(b, automationName ?? label);
        b.Click += (_, _) => click();
        return b;
    }

    // MARK: - Glyphs (34 px tile with a white stroked symbol, as on the Mac)

    public enum Glyph { Word, Searchable, Photos, Done, Refused, Stopped, Info }

    static readonly Dictionary<Glyph, string> Symbol = new()
    {
        [Glyph.Word] = "M11,8 L20,8 L25,13 L25,26 L11,26 Z M20,8 L20,13 L25,13 M13.6,16 L15.2,22 L17,17.4 L18.8,22 L20.4,16",
        [Glyph.Searchable] = "M20.5,15 A5.5,5.5 0 1 1 9.5,15 A5.5,5.5 0 1 1 20.5,15 Z M19,19 L25,25 M12.5,13.5 L17.5,13.5 M12.5,16.5 L16,16.5",
        [Glyph.Photos] = "M8,10 L26,10 L26,24 L8,24 Z M8,21 L13,16 L17,20 L20,17 L26,23 M22.5,13.5 A1.5,1.5 0 1 1 19.5,13.5 A1.5,1.5 0 1 1 22.5,13.5 Z",
        [Glyph.Done] = "M10.5,17.5 L15,22 L24,12.5",
        [Glyph.Refused] = "M8,10 L26,10 L26,24 L8,24 Z M8,15 L26,15 M8,19.5 L26,19.5 M14.5,10 L14.5,24 M20.5,10 L20.5,24",
        [Glyph.Stopped] = "M12,12 L22,12 L22,22 L12,22 Z",
        [Glyph.Info] = "M10.5,17.5 L15,22 L24,12.5",
    };

    public static FrameworkElement Tile(Glyph g)
    {
        Brush fill, stroke;
        switch (g)
        {
            case Glyph.Refused:
                fill = new SolidColorBrush(Color.FromRgb(0xF3, 0xE3, 0xC7)); stroke = new SolidColorBrush(Color.FromRgb(0x8A, 0x5A, 0x0B)); break;
            case Glyph.Stopped:
                fill = new SolidColorBrush(Color.FromRgb(0xE0, 0xE0, 0xE0)); stroke = new SolidColorBrush(Color.FromRgb(0x5C, 0x5C, 0x5C)); break;
            default:
                fill = new LinearGradientBrush(TealC, Color.FromRgb(0x14, 0xB8, 0xA6), new Point(0, 0), new Point(1, 1)); stroke = Brushes.White; break;
        }
        var grid = new Grid { Width = 34, Height = 34, VerticalAlignment = VerticalAlignment.Top };
        grid.Children.Add(new Border { CornerRadius = new CornerRadius(9), Background = fill });
        grid.Children.Add(new WpfPath
        {
            Data = Geometry.Parse(Symbol[g]), Stroke = stroke, StrokeThickness = 1.8,
            StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        });
        System.Windows.Automation.AutomationProperties.SetName(grid, g.ToString());
        return grid;
    }

    // MARK: - Row status icons (16 px)

    public enum RowIcon { Done, Working, Waiting, Problem }

    public static FrameworkElement Icon(RowIcon k)
    {
        var c = new Canvas { Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 1, 0, 0) };
        switch (k)
        {
            case RowIcon.Done:
                c.Children.Add(new Ellipse { Width = 16, Height = 16, Fill = Teal });
                c.Children.Add(new WpfPath { Data = Geometry.Parse("M4.5,8.3 L7,10.8 L11.6,5.6"), Stroke = Brushes.White, StrokeThickness = 1.6, StrokeEndLineCap = PenLineCap.Round, StrokeStartLineCap = PenLineCap.Round });
                break;
            case RowIcon.Working:
                c.Children.Add(new Ellipse { Width = 15, Height = 15, Margin = new Thickness(0.5), Stroke = Teal, StrokeThickness = 1.6, StrokeDashArray = new DoubleCollection { 1.2, 1.6 } });
                break;
            case RowIcon.Waiting:
                c.Children.Add(new Ellipse { Width = 15, Height = 15, Margin = new Thickness(0.5), Stroke = Grey, StrokeThickness = 1.4 });
                break;
            case RowIcon.Problem:
                c.Children.Add(new Ellipse { Width = 16, Height = 16, Fill = Orange });
                c.Children.Add(new WpfPath { Data = Geometry.Parse("M8,4 L8,9 M8,11.6 L8,11.7"), Stroke = Brushes.White, StrokeThickness = 1.8, StrokeEndLineCap = PenLineCap.Round, StrokeStartLineCap = PenLineCap.Round });
                break;
        }
        return c;
    }

    public static FrameworkElement Lock() => new WpfPath
    {
        Data = Geometry.Parse("M3.5,6 L3.5,4.2 A2.5,2.5 0 0 1 8.5,4.2 L8.5,6 M2,6 L10,6 L10,11.5 L2,11.5 Z"),
        Stroke = Secondary, StrokeThickness = 1.2, Width = 12, Height = 12, Margin = new Thickness(0, 0, 6, 0),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// The floating panel every Jack surface uses: light, radius 16, hairline border, soft shadow.
    /// The outer margin leaves room for the shadow inside the transparent window.
    public static Border PanelBorder(UIElement child) => new()
    {
        Margin = new Thickness(14), CornerRadius = new CornerRadius(16), Background = Panel,
        BorderBrush = Hairline, BorderThickness = new Thickness(1), Child = child,
        Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 22, ShadowDepth = 4, Direction = 270, Opacity = 0.18 },
    };
}
